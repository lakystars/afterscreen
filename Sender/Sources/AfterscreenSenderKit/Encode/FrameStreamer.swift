import CoreVideo
import Foundation
import Metal
import AfterscreenCore

/// Bytes and tiles sent since the previous read
struct FrameCounters {
    /// Everything on the wire: tiles, refinements, video
    var bytes = 0
    /// Tile frames and refinements, before and after LZ4
    var rawTileBytes = 0
    var tileWireBytes = 0
    /// New frames: tiles that changed, tiles in the screen
    var dirtyTiles = 0
    var totalTiles = 0
    /// New frames: processing start to send, summed
    var encodeMs = 0.0
    var encodedFrames = 0
    /// Tiles the receiver shows lossy after the latest frame
    var lossyTiles = 0
}

enum FrameStreamerError: Error, CustomStringConvertible {
    case tileEncoder

    var description: String { "Metal tile encoder unavailable" }
}

/// Capture → gate → tile encoder → outbox → connection
/// Hybrid path adds the video layer; own serial queue
final class FrameStreamer {
    /// Queued tile frame; hybrid path also awaits its video picture
    private struct Outgoing {
        var frame: EncodedFrame?
        var refinement = false
        var waitsForVideo = false
        var video: VideoEncoder.Output?
        var changedTiles = 0
        /// Processing start: encode time, and the video timestamp
        var created = ProcessInfo.processInfo.systemUptime
    }

    let sent = RateCounter()
    let drops = RateCounter(window: 60)
    let gpuMeter = GPUTimeMeter()

    /// Queue-only; a handover replaces it between frames
    private var connection: Connection
    /// Handing over: nothing goes out until the receiver reads here
    private var switching: Connection?
    /// Link lost: nothing goes out until `resume`
    private var held = false
    private var sending: Bool { switching == nil && !held }
    // Per-item autorelease: a busy queue would retain Metal objects
    private let queue = DispatchQueue(label: "afterscreen.frames", qos: .userInteractive, autoreleaseFrequency: .workItem)
    /// Paced to the stream's rate, 2 ms early for jitter
    private var gate: FrameGate<CapturedFrame>
    private var pumpTimer: DispatchSourceTimer?
    /// Sends BC7 reference of settled BC1 tiles
    /// Fires even without new frames
    private var refineTimer: DispatchSourceTimer?
    private var tile: (encoder: TileEncoder, cache: CVMetalTextureCache, packer: TilePacker)?
    private var compression: CompressionPolicy
    /// Hybrid path: video for tiles in motion
    /// nil on the tile path or after failure (BC1 fallback)
    private var video: VideoEncoder?
    private var videoCodec = VideoCodec.hevc
    /// Bumped when the encoder goes: its late outputs are dropped
    private var videoGeneration = 0
    private var videoKeyframe = true
    /// Frames leave in capture order
    /// A frame awaiting its video holds back later ones
    private var outbox: [Outgoing] = []
    private let lock = NSLock()
    private var keyframeRequested = true
    /// Since the last encoded frame: the socket held two back
    /// Stream lags source: tile changed in consecutive frames is moving
    private var queueWasFull = false
    /// A refinement waits for the link to drain
    private var refinePending = false
    private var counters = FrameCounters()
    /// Hybrid path: video bitrate follows the link's queueing
    private var rate: RateControl?
    private var rateTimer: DispatchSourceTimer?
    /// Settle budget at the starting bitrate
    private var settleBase = 0
    private var offeredFrames = 0
    private var rateTicks = 0
    /// Least send buffer and receiver window since the last decision
    private var leastBuffered: Int?
    private var leastWindow: Int?
    /// A whole-screen frame was encoded since the last decision
    private var sentFullFrame = false
    private var lastSent: (bytes: UInt64, at: TimeInterval)?
    /// Video bitrate now and from the probe; under `lock`
    private var bitrates: (now: Int, start: Int)?

    init(config: StreamConfig, capacityGbps: Double?, connection: Connection) throws {
        self.connection = connection
        compression = CompressionPolicy(capacityGbps: capacityGbps, fps: config.frameRate)
        gate = FrameGate(interval: 1 / config.frameRate - 0.002)
        var cache: CVMetalTextureCache?
        let geometry = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
        guard let device = MTLCreateSystemDefaultDevice(), let encoder = try? TileEncoder(device: device, geometry: geometry),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache else {
            throw FrameStreamerError.tileEncoder
        }
        tile = (encoder, textureCache, TilePacker())
        apply(config, capacityGbps: capacityGbps)
        watchWrites(connection)
        pumpTimer = makeTimer { [weak self] in self?.pump() }
        refineTimer = makeTimer { [weak self] in self?.refine() }
    }

    /// What the link decides: path, video layer, rate control, limits
    /// Init, or the queue during a handover
    private func apply(_ config: StreamConfig, capacityGbps: Double?) {
        guard let tile = tile else { return }
        let geometry = tile.encoder.geometry, fps = config.frameRate
        // A resume off Thunderbolt drops 120 fps
        if abs(gate.interval - (1 / fps - 0.002)) > 1e-6 { gate = FrameGate(interval: 1 / fps - 0.002) }
        compression = CompressionPolicy(capacityGbps: capacityGbps, fps: fps)
        tile.encoder.bc7MotionLimit = PathPolicy.bc7MotionTiles(capacityGbps: capacityGbps, tileBytes: geometry.tileBytes, fps: fps)
        // Waits end here: the replaced encoder's outputs are dropped
        // Old video must not reach a receiver now on tiles
        for i in outbox.indices {
            outbox[i].waitsForVideo = false
            if config.video == nil { outbox[i].video = nil }
        }
        video = nil
        videoGeneration += 1
        rate = nil
        settleBase = 0
        tile.encoder.motion = .bc1
        tile.encoder.settleLimit = .max
        var rates: (now: Int, start: Int)?
        if let layer = config.video, let video = VideoEncoder(layer: layer, fps: fps) {
            videoCodec = layer.codec
            tile.encoder.motion = .video
            settleBase = PathPolicy.settleTiles(capacityGbps: capacityGbps, tileBytes: geometry.tileBytes, fps: fps)
            tile.encoder.settleLimit = settleBase
            self.video = video
            rate = RateControl(start: layer.bitrate, fps: fps)
            rates = (layer.bitrate, layer.bitrate)
        }
        lock.lock()
        bitrates = rates
        lock.unlock()
        videoKeyframe = true
        offeredFrames = 0
        sentFullFrame = false
        rateTimer?.cancel()
        rateTimer = rate == nil ? nil : DispatchSource.repeating(on: queue, every: 0.25, after: 0.25) { [weak self] in self?.sampleLink() }
    }

    /// Written frame frees the link: retry held frame, no polling
    private func watchWrites(_ c: Connection) {
        c.onFrameWritten = { [weak self] in
            self?.queue.async { self?.wake() }
        }
    }

    // MARK: - Handover

    /// Any queue: stops sending, then marks the old connection's end
    /// Frames queued there go first; `finishSwitch` resumes on `next`
    func switchConnection(to next: Connection) {
        queue.async { [self] in
            guard switching == nil else { return }
            switching = next
            connection.send(Message(type: .switchover))
        }
    }

    /// Any queue: link died; the gate keeps the newest frame
    func hold() {
        queue.async { [self] in held = true }
    }

    /// Any queue: a lost link replaced by `next`
    /// Frames on the dead link may be lost: all again
    func resume(on next: Connection, config: StreamConfig, capacityGbps: Double?) {
        queue.async { [self] in
            held = false
            switching = nil
            connection.onFrameWritten = nil
            connection = next
            watchWrites(next)
            lastSent = nil
            leastBuffered = nil
            leastWindow = nil
            queueWasFull = false
            // Deltas against a picture the receiver may lack
            outbox.removeAll()
            next.send(.reconfigure, json: config)
            apply(config, capacityGbps: capacityGbps)
            tile?.encoder.resyncAll()
            refinePending = true
            wake()
        }
    }

    /// Any queue: the receiver reads `next` now
    /// `config`: the new link's, sent there before any frame
    func finishSwitch(config: StreamConfig? = nil, capacityGbps: Double? = nil) {
        queue.async { [self] in
            guard let next = switching else { return }
            switching = nil
            connection.onFrameWritten = nil
            connection = next
            watchWrites(next)
            // The old socket's counters say nothing of this one
            lastSent = nil
            leastBuffered = nil
            leastWindow = nil
            queueWasFull = false
            if let config = config {
                next.send(.reconfigure, json: config)
                apply(config, capacityGbps: capacityGbps)
            } else {
                rate?.newLink()
            }
            // Frames held while switching: out before the next capture
            drain()
            wake()
        }
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
            offeredFrames += 1
            if let unsent = gate.pending { frame.dirty = CapturedFrame.merge(unsent.dirty, into: frame.dirty) }
            // Replaced while the gate was open: a frame lost
            // Replaced while it paces: a capture above the stream's rate
            // Neither is congestion; `pump` reads the socket for that
            let open = gate.delay(now: ProcessInfo.processInfo.systemUptime) == 0
            if gate.offer(frame), open { drops.tick() }
            pump()
        }
    }

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    /// Drops encoders and any held frame
    /// `completion`: streamer queue, once nothing more is sent
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            pumpTimer?.cancel()
            pumpTimer = nil
            refineTimer?.cancel()
            refineTimer = nil
            rateTimer?.cancel()
            rateTimer = nil
            gate = FrameGate(interval: gate.interval)
            outbox = []
            tile = nil
            video = nil
            completion?()
        }
    }

    /// Video bitrate now and from the probe
    /// nil on the tile path
    var videoBitrates: (now: Int, start: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return bitrates
    }

    func takeCounters() -> FrameCounters {
        lock.lock()
        defer {
            counters = FrameCounters()
            lock.unlock()
        }
        return counters
    }

    // MARK: - Bitrate

    /// Four samples a second; the least buffer filters bursts
    /// The first second only starts the send-rate clock
    private func sampleLink() {
        guard rate != nil, video != nil, let tcp = connection.tcpInfo() else { return }
        if lastSent == nil { lastSent = (tcp.sentBytes, ProcessInfo.processInfo.systemUptime) }
        leastBuffered = min(leastBuffered ?? tcp.sendBuffered, tcp.sendBuffered)
        leastWindow = min(leastWindow ?? tcp.peerWindow, tcp.peerWindow)
        rateTicks += 1
        if rateTicks % 4 == 0 { adjustRate(tcp) }
    }

    /// Once a second: socket signals, then the encoder
    /// Settle tiles share the link: scaled alike
    private func adjustRate(_ tcp: TCPInfo) {
        guard var control = rate, let video = video else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var sentBps = 0.0
        if let last = lastSent, now > last.at, tcp.sentBytes >= last.bytes {
            sentBps = Double(tcp.sentBytes - last.bytes) * 8 / (now - last.at)
        }
        lastSent = (tcp.sentBytes, now)
        let sample = RateControl.Sample(frames: offeredFrames, sentBps: sentBps, rttMs: tcp.rttMs, buffered: leastBuffered ?? 0,
                                        receiverLimited: (leastWindow ?? .max) < RateControl.stalledWindow, fullFrame: sentFullFrame)
        offeredFrames = 0
        leastBuffered = nil
        leastWindow = nil
        sentFullFrame = false
        let before = control.bitrate
        let changed = control.update(sample)
        rate = control
        guard let next = changed else { return }
        video.setBitrate(next)
        tile?.encoder.settleLimit = max(16, settleBase * next / control.start)
        lock.lock()
        bitrates?.now = next
        lock.unlock()
        if SenderSession.logStats {
            let why = String(format: "rtt %.0f ms, buffered %d KB, sent %.0f Mbps", tcp.rttMs, sample.buffered / 1024, sentBps / 1e6)
            FileHandle.standardError.write(Data("[sender] video bitrate \(before / 1_000_000) → \(next / 1_000_000) Mbps (\(why))\n".utf8))
        }
    }

    // MARK: - Frame queue

    private func wake() {
        pump()
        if refinePending { refine() }
    }

    /// Frames queued on the wire or still encoding
    /// Two keep both link and encoder busy
    private var inFlight: Int { connection.queuedFrames + outbox.count }

    /// Sends the held frame once the gate opens
    /// Busy link or encoder: woken when a frame leaves
    /// No timer runs while nothing is held
    private func pump() {
        guard !connection.isClosed, gate.pending != nil, sending else { return }
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
        let started = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let forceKey = keyframeRequested
        keyframeRequested = false
        lock.unlock()
        if forceKey {
            videoKeyframe = true
            sentFullFrame = true
        }
        let pixelBuffer = captured.pixelBuffer
        guard let tile = tile else { return }
        var cvTexture: CVMetalTexture?
        let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked ? .bgr10a2Unorm : .bgra8Unorm
        CVMetalTextureCacheCreateTextureFromImage(nil, tile.cache, pixelBuffer, nil, format,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvt = cvTexture, let texture = CVMetalTextureGetTexture(cvt) else { return }
        var out = Outgoing(frame: tile.encoder.encode(texture: texture, forceAll: forceKey, dirty: captured.dirty, congested: queueWasFull))
        out.created = started
        out.changedTiles = tile.encoder.changedTiles
        gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
        if let video = video, tile.encoder.lossyTiles > 0 {
            let generation = videoGeneration
            out.waitsForVideo = video.encode(pixelBuffer, time: out.created, forceKeyframe: videoKeyframe) { [weak self] output in
                self?.queue.async { self?.videoDone(output, generation: generation) }
            }
            if out.waitsForVideo { videoKeyframe = false } else { fallBackToBC1() }
        }
        if out.frame != nil || out.waitsForVideo { outbox.append(out) }
        drain()
        scheduleRefine()
    }

    /// Encoder outputs arrive in submission order
    /// A replaced encoder's late outputs fit no queued frame
    private func videoDone(_ output: VideoEncoder.Output, generation: Int) {
        guard tile != nil, generation == videoGeneration, let i = outbox.firstIndex(where: { $0.waitsForVideo }) else { return }
        outbox[i].waitsForVideo = false
        outbox[i].video = output
        if case .failed = output { fallBackToBC1() }
        drain()
        wake()
    }

    /// Lossy tiles settle to BC7; motion continues as BC1
    /// Frames awaiting the dropped encoder go out without video
    /// Its callbacks may never arrive
    private func fallBackToBC1() {
        tile?.encoder.motion = .bc1
        tile?.encoder.settleLimit = settleBase
        video = nil
        videoGeneration += 1
        rateTimer?.cancel()
        rateTimer = nil
        lock.lock()
        bitrates = nil
        lock.unlock()
        for i in outbox.indices { outbox[i].waitsForVideo = false }
        drain()
    }

    /// Sends ready frames in order
    /// Video picture first, then the tile frame presenting it
    private func drain() {
        guard let tile = tile, sending else { return }
        while let first = outbox.first, !first.waitsForVideo {
            outbox.removeFirst()
            var videoBytes = 0
            if case let .frame(keyframe, avcc, sets)? = first.video {
                if keyframe { connection.send(Message(type: .videoParams, payload: VideoWire.params(codec: videoCodec, sets: sets))) }
                let parts = VideoWire.frame(keyframe: keyframe, avcc: avcc)
                connection.send(.videoFrame, parts: parts)
                videoBytes = parts.reduce(0) { $0 + $1.count }
            }
            guard let frame = first.frame ?? (videoBytes > 0 ? EncodedFrame(runs: [], data: Data()) : nil) else { continue }
            send(frame, tile.encoder, tile.packer, first, videoBytes: videoBytes)
        }
    }

    private func refine() {
        guard let tile = tile, !connection.isClosed else { return }
        // Handing over: `wake` refines once the switch is done
        refinePending = inFlight >= 2 || !sending
        guard !refinePending else { return }
        if let frame = tile.encoder.refine() {
            gpuMeter.add(seconds: tile.encoder.lastGPUSeconds)
            outbox.append(Outgoing(frame: frame, refinement: true))
            drain()
        }
        scheduleRefine()
    }

    private func scheduleRefine() {
        guard let due = tile?.encoder.nextRefinement() else { return }
        refineTimer?.schedule(deadline: .now() + due)
    }

    /// Refinements re-send settled tiles; count as bytes, not frames
    private func send(_ frame: EncodedFrame, _ encoder: TileEncoder, _ packer: TilePacker, _ out: Outgoing, videoBytes: Int) {
        let g = encoder.geometry
        let packed = packer.pack(frame, geometry: g, compression: compression.next(rawBytes: frame.data.count, queueWasFull: queueWasFull))
        compression.record(rawBytes: packed.lz4In, wireBytes: packed.lz4Out)
        queueWasFull = false
        connection.send(.tileFrame, flags: out.refinement ? TileFlags.refinement : 0, parts: packed.parts)
        if out.refinement {
            count(FrameCounters(bytes: packed.wireBytes, rawTileBytes: frame.data.count, tileWireBytes: packed.wireBytes,
                                lossyTiles: encoder.lossyTiles))
            return
        }
        sent.tick()
        // Video-only frame: its tile header alone would skew the ratio
        count(FrameCounters(bytes: packed.wireBytes + videoBytes, rawTileBytes: frame.data.count,
                            tileWireBytes: frame.data.isEmpty ? 0 : packed.wireBytes,
                            dirtyTiles: out.changedTiles, totalTiles: g.tileCount,
                            encodeMs: (ProcessInfo.processInfo.systemUptime - out.created) * 1000, encodedFrames: 1,
                            lossyTiles: encoder.lossyTiles))
    }

    private func count(_ c: FrameCounters) {
        lock.lock()
        counters.bytes += c.bytes
        counters.rawTileBytes += c.rawTileBytes
        counters.tileWireBytes += c.tileWireBytes
        counters.dirtyTiles += c.dirtyTiles
        counters.totalTiles += c.totalTiles
        counters.encodeMs += c.encodeMs
        counters.encodedFrames += c.encodedFrames
        counters.lossyTiles = c.lossyTiles
        lock.unlock()
    }
}

