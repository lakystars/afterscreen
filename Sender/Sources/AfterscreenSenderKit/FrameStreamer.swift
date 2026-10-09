import CoreVideo
import Foundation
import Metal
import AfterscreenCore

/// Bytes and tiles sent since the previous read
struct FrameCounters {
    var bytes = 0
    var rawTileBytes = 0
    var dirtyTiles = 0
    var totalTiles = 0
    var encodeMs = 0.0
}

enum FrameStreamerError: Error, CustomStringConvertible {
    case tileEncoder
    case videoEncoder

    var description: String {
        switch self {
        case .tileEncoder: return "Metal tile encoder unavailable"
        case .videoEncoder: return "Video encoder unavailable"
        }
    }
}

/// Captured frames → gate → tile or video encoder → connection, on its own queue
final class FrameStreamer {
    let sent = RateCounter()
    let drops = RateCounter(window: 60)
    let gpuMeter = GPUTimeMeter()

    private let connection: Connection
    // Per-item autorelease: a busy queue would keep Metal objects alive
    private let queue = DispatchQueue(label: "afterscreen.frames", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private var gate = FrameGate<CapturedFrame>(interval: 1.0 / 60 - 0.002)
    private var pumpTimer: DispatchSourceTimer?
    /// Sends the BC7 reference of BC1 tiles once they settle, even when no new frames arrive
    private var refineTimer: DispatchSourceTimer?
    private var tile: (encoder: TileEncoder, cache: CVMetalTextureCache, packer: TilePacker)?
    private var compression: CompressionPolicy
    private var video: VideoEncoder?
    private let lock = NSLock()
    private var keyframeRequested = true
    /// The send queue held a frame back since the last encoded frame
    private var queueWasFull = false
    /// A refinement waits for the link to drain
    private var refinePending = false
    private var counters = FrameCounters()

    init(config: StreamConfig, capacityGbps: Double?, connection: Connection) throws {
        self.connection = connection
        compression = CompressionPolicy(capacityGbps: capacityGbps)
        if config.path == .tile {
            var cache: CVMetalTextureCache?
            guard let device = MTLCreateSystemDefaultDevice(),
                  let encoder = try? TileEncoder(device: device, geometry: TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)),
                  CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache else {
                throw FrameStreamerError.tileEncoder
            }
            tile = (encoder, textureCache, TilePacker())
        } else {
            guard let codec = config.codec,
                  let encoder = VideoEncoder(codec: codec, size: config.streamPixels, bitrate: PathPolicy.bitrate(for: config.streamPixels)) else {
                throw FrameStreamerError.videoEncoder
            }
            encoder.onParams = { [connection] codec, sets in
                connection.send(Message(type: .videoParams, payload: VideoWire.params(codec: codec, sets: sets)))
            }
            encoder.onFrame = { [weak self, weak encoder] keyframe, avcc in
                guard let self = self, let encoder = encoder else { return }
                let payload = VideoWire.frame(keyframe: keyframe, avcc: avcc)
                self.connection.send(Message(type: .videoFrame, payload: payload))
                self.sent.tick()
                self.count(FrameCounters(bytes: payload.count, encodeMs: encoder.lastEncodeMs))
            }
            video = encoder
        }
        // A written frame frees the link: retry the held frame then instead of polling
        connection.onFrameWritten = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                self.pump()
                if self.refinePending { self.refine() }
            }
        }
        pumpTimer = makeTimer { [weak self] in self?.pump() }
        refineTimer = makeTimer { [weak self] in self?.refine() }
    }

    private func makeTimer(_ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler(handler: handler)
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        return timer
    }

    /// Any queue
    func offer(_ frame: CapturedFrame) {
        queue.async { [self] in
            var frame = frame
            if let unsent = gate.pending { frame.dirty = CapturedFrame.merge(unsent.dirty, into: frame.dirty) }
            if gate.offer(frame) { drops.tick() }
            pump()
        }
    }

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    /// Drops encoders and any held frame
    func stop() {
        queue.async { [self] in
            pumpTimer?.cancel()
            pumpTimer = nil
            refineTimer?.cancel()
            refineTimer = nil
            gate = FrameGate(interval: gate.interval)
            tile = nil
            video = nil
        }
    }

    func takeCounters() -> FrameCounters {
        lock.lock()
        defer {
            counters = FrameCounters()
            lock.unlock()
        }
        return counters
    }

    // MARK: - Frame queue

    /// Sends the held frame once the gate opens; a busy link wakes it when a frame is written.
    /// No timer runs while nothing is held
    private func pump() {
        guard !connection.isClosed, gate.pending != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let busy = connection.queuedFrames >= 2
        if busy {
            queueWasFull = true
            return
        }
        if let frame = gate.take(now: now, busy: false) {
            process(frame)
        } else {
            pumpTimer?.schedule(deadline: .now() + gate.delay(now: now))
        }
    }

    private func process(_ captured: CapturedFrame) {
        lock.lock()
        let forceKey = keyframeRequested
        keyframeRequested = false
        lock.unlock()
        let pixelBuffer = captured.pixelBuffer
        guard let tile = tile else {
            video?.encode(pixelBuffer, forceKeyframe: forceKey)
            return
        }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, tile.cache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvt = cvTexture, let texture = CVMetalTextureGetTexture(cvt) else { return }
        let frame = tile.encoder.encode(texture: texture, forceAll: forceKey, dirty: captured.dirty, congested: queueWasFull)
        gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
        if let frame = frame { send(frame, tile.encoder, tile.packer, refinement: false) }
        scheduleRefine()
    }

    private func refine() {
        guard let tile = tile, !connection.isClosed else { return }
        refinePending = connection.queuedFrames >= 2
        guard !refinePending else { return }
        if let frame = tile.encoder.refine() {
            gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
            send(frame, tile.encoder, tile.packer, refinement: true)
        }
        scheduleRefine()
    }

    private func scheduleRefine() {
        guard let due = tile?.encoder.nextRefinement() else { return }
        refineTimer?.schedule(deadline: .now() + due)
    }

    /// Refinements re-send settled tiles; they count as bytes, not as frames
    private func send(_ frame: EncodedFrame, _ encoder: TileEncoder, _ packer: TilePacker, refinement: Bool) {
        let g = encoder.geometry
        let packed = packer.pack(frame, geometry: g, compression: compression.next(rawBytes: frame.data.count, queueWasFull: queueWasFull))
        compression.record(rawBytes: packed.lz4In, wireBytes: packed.lz4Out)
        queueWasFull = false
        connection.send(.tileFrame, parts: packed.parts)
        if refinement {
            count(FrameCounters(bytes: packed.wireBytes, encodeMs: encoder.lastGPUSeconds * 1000))
            return
        }
        sent.tick()
        count(FrameCounters(bytes: packed.wireBytes, rawTileBytes: frame.data.count, dirtyTiles: frame.tileCount,
                            totalTiles: g.tileCount, encodeMs: encoder.lastGPUSeconds * 1000))
    }

    private func count(_ c: FrameCounters) {
        lock.lock()
        counters.bytes += c.bytes
        counters.rawTileBytes += c.rawTileBytes
        counters.dirtyTiles += c.dirtyTiles
        counters.totalTiles += c.totalTiles
        counters.encodeMs = c.encodeMs
        lock.unlock()
    }
}
