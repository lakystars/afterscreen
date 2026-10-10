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
    /// Tiles the receiver shows lossy after the latest frame
    var lossyTiles = 0
}

enum FrameStreamerError: Error, CustomStringConvertible {
    case tileEncoder

    var description: String { "Metal tile encoder unavailable" }
}

/// Captured frames → gate → tile encoder (and the hybrid path's video layer) → outbox → connection, on its own queue
final class FrameStreamer {
    /// A tile frame waiting for its turn; on the hybrid path also for its video picture
    private struct Outgoing {
        var frame: EncodedFrame?
        var refinement = false
        var waitsForVideo = false
        var video: VideoEncoder.Output?
        var gpuMs = 0.0
        var created = ProcessInfo.processInfo.systemUptime
    }

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
    /// Hybrid path: shows tiles in motion; nil on the tile path, or after it failed (motion falls back to BC1)
    private var video: VideoEncoder?
    private var videoCodec = VideoCodec.hevc
    private var videoKeyframe = true
    /// Frames leave in capture order: a frame whose video is still encoding holds back the ones after it
    private var outbox: [Outgoing] = []
    private let lock = NSLock()
    private var keyframeRequested = true
    /// The send queue held a frame back, or a newer capture replaced an unsent one, since the last encoded frame:
    /// the stream runs behind its source, so a tile changed in consecutive frames is moving
    private var queueWasFull = false
    /// A refinement waits for the link to drain
    private var refinePending = false
    private var counters = FrameCounters()

    init(config: StreamConfig, capacityGbps: Double?, connection: Connection) throws {
        self.connection = connection
        compression = CompressionPolicy(capacityGbps: capacityGbps)
        var cache: CVMetalTextureCache?
        let geometry = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
        guard let device = MTLCreateSystemDefaultDevice(), let encoder = try? TileEncoder(device: device, geometry: geometry),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache else {
            throw FrameStreamerError.tileEncoder
        }
        tile = (encoder, textureCache, TilePacker())
        encoder.bc7MotionLimit = PathPolicy.bc7MotionTiles(capacityGbps: capacityGbps, tileBytes: geometry.tileBytes)
        if let layer = config.video, let video = VideoEncoder(layer: layer) {
            videoCodec = layer.codec
            encoder.motion = .video
            encoder.settleLimit = PathPolicy.settleTiles(capacityGbps: capacityGbps, tileBytes: geometry.tileBytes)
            self.video = video
        }
        // A written frame frees the link: retry the held frame then instead of polling
        connection.onFrameWritten = { [weak self] in
            self?.queue.async { self?.wake() }
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
            if gate.offer(frame) {
                drops.tick()
                queueWasFull = true
            }
            pump()
        }
    }

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    /// Drops encoders and any held frame; `completion` runs on the streamer queue once nothing more is sent
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            pumpTimer?.cancel()
            pumpTimer = nil
            refineTimer?.cancel()
            refineTimer = nil
            gate = FrameGate(interval: gate.interval)
            outbox = []
            tile = nil
            video = nil
            completion?()
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

    private func wake() {
        pump()
        if refinePending { refine() }
    }

    /// Two frames on the wire or still encoding is enough to keep the link and the encoder busy
    private var inFlight: Int { connection.queuedFrames + outbox.count }

    /// Sends the held frame once the gate opens; a busy link or encoder wakes it when a frame leaves.
    /// No timer runs while nothing is held
    private func pump() {
        guard !connection.isClosed, gate.pending != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if connection.queuedFrames >= 2 { queueWasFull = true }
        guard inFlight < 2 else { return }
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
        if forceKey { videoKeyframe = true }
        let pixelBuffer = captured.pixelBuffer
        guard let tile = tile else { return }
        var cvTexture: CVMetalTexture?
        let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked ? .bgr10a2Unorm : .bgra8Unorm
        CVMetalTextureCacheCreateTextureFromImage(nil, tile.cache, pixelBuffer, nil, format,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvt = cvTexture, let texture = CVMetalTextureGetTexture(cvt) else { return }
        var out = Outgoing(frame: tile.encoder.encode(texture: texture, forceAll: forceKey, dirty: captured.dirty, congested: queueWasFull))
        out.gpuMs = tile.encoder.lastGPUSeconds * 1000
        gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
        if let video = video, tile.encoder.lossyTiles > 0 {
            out.waitsForVideo = video.encode(pixelBuffer, time: out.created, forceKeyframe: videoKeyframe) { [weak self] output in
                self?.queue.async { self?.videoDone(output) }
            }
            if out.waitsForVideo { videoKeyframe = false } else { fallBackToBC1() }
        }
        if out.frame != nil || out.waitsForVideo { outbox.append(out) }
        drain()
        scheduleRefine()
    }

    /// Encoder outputs arrive in submission order
    private func videoDone(_ output: VideoEncoder.Output) {
        guard tile != nil, let i = outbox.firstIndex(where: { $0.waitsForVideo }) else { return }
        outbox[i].waitsForVideo = false
        outbox[i].video = output
        if case .failed = output { fallBackToBC1() }
        drain()
        wake()
    }

    /// Lossy tiles settle to BC7, and motion continues as BC1
    private func fallBackToBC1() {
        tile?.encoder.motion = .bc1
        video = nil
    }

    /// Sends ready frames in order: the video picture, then the tile frame that presents it
    private func drain() {
        guard let tile = tile else { return }
        while let first = outbox.first, !first.waitsForVideo {
            outbox.removeFirst()
            var videoBytes = 0
            if case let .frame(keyframe, avcc, sets)? = first.video {
                if keyframe { connection.send(Message(type: .videoParams, payload: VideoWire.params(codec: videoCodec, sets: sets))) }
                let payload = VideoWire.frame(keyframe: keyframe, avcc: avcc)
                connection.send(Message(type: .videoFrame, payload: payload))
                videoBytes = payload.count
            }
            guard let frame = first.frame ?? (videoBytes > 0 ? EncodedFrame(runs: [], data: Data()) : nil) else { continue }
            send(frame, tile.encoder, tile.packer, first, videoBytes: videoBytes)
        }
    }

    private func refine() {
        guard let tile = tile, !connection.isClosed else { return }
        refinePending = inFlight >= 2
        guard !refinePending else { return }
        if let frame = tile.encoder.refine() {
            gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
            outbox.append(Outgoing(frame: frame, refinement: true, gpuMs: tile.encoder.lastGPUSeconds * 1000))
            drain()
        }
        scheduleRefine()
    }

    private func scheduleRefine() {
        guard let due = tile?.encoder.nextRefinement() else { return }
        refineTimer?.schedule(deadline: .now() + due)
    }

    /// Refinements re-send settled tiles; they count as bytes, not as frames.
    /// Encode time spans capture to send, which on the hybrid path includes the video encoder
    private func send(_ frame: EncodedFrame, _ encoder: TileEncoder, _ packer: TilePacker, _ out: Outgoing, videoBytes: Int) {
        let g = encoder.geometry
        let packed = packer.pack(frame, geometry: g, compression: compression.next(rawBytes: frame.data.count, queueWasFull: queueWasFull))
        compression.record(rawBytes: packed.lz4In, wireBytes: packed.lz4Out)
        queueWasFull = false
        connection.send(.tileFrame, parts: packed.parts)
        let encodeMs = out.video == nil ? out.gpuMs : (ProcessInfo.processInfo.systemUptime - out.created) * 1000
        if out.refinement {
            count(FrameCounters(bytes: packed.wireBytes, encodeMs: encodeMs, lossyTiles: encoder.lossyTiles))
            return
        }
        sent.tick()
        count(FrameCounters(bytes: packed.wireBytes + videoBytes, rawTileBytes: frame.data.count, dirtyTiles: frame.tileCount,
                            totalTiles: g.tileCount, encodeMs: encodeMs, lossyTiles: encoder.lossyTiles))
    }

    private func count(_ c: FrameCounters) {
        lock.lock()
        counters.bytes += c.bytes
        counters.rawTileBytes += c.rawTileBytes
        counters.dirtyTiles += c.dirtyTiles
        counters.totalTiles += c.totalTiles
        if c.totalTiles > 0 || c.encodeMs > 0 { counters.encodeMs = c.encodeMs }
        counters.lossyTiles = c.lossyTiles
        lock.unlock()
    }
}

