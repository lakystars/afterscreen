import Foundation
import AfterscreenCore

/// Screen side of a session. begin/end/cursor run on the main queue;
/// showTiles and video calls run on the session's serial decode queue
public protocol StreamDisplay: AnyObject {
    func begin(config: StreamConfig)
    /// Decode queue: drop decoder and texture state from the previous stream
    func prepare(config: StreamConfig)
    /// Decode queue, after the session ends: free textures and staging buffers
    func releaseDecodeResources()
    func end(reason: String)
    /// false when the tile data fails to decode
    func showTiles(_ frame: TileFrame) -> Bool
    /// false when the decoder cannot be created
    func setVideoParams(codec: VideoCodec, parameterSets: [Data]) -> Bool
    /// false when the frame failed to decode
    func showVideoFrame(avcc: Data, keyframe: Bool) -> Bool
    func cursor(x: Float, y: Float, visible: Bool)
    func cursorImage(_ image: CursorImage)
    var gpuMeter: GPUTimeMeter { get }
    var displayedFPS: Double { get }
    var lateFrames: Int { get }
    var uploadMs: Double { get }
    var decodeMs: Double { get }
}

/// One sender connection: protocol handling, probe, ping, stats
public final class ReceiverSession {
    public var onEnd: ((String) -> Void)?
    public var onPeer: ((Hello) -> Void)?
    public private(set) var peer: Hello?
    public private(set) var config: StreamConfig?

    private let connection: Connection
    private let hardware: Welcome
    private weak var display: StreamDisplay?
    private let queue = DispatchQueue(label: "afterscreen.session")
    // Per-item autorelease: a busy queue would keep payloads alive via Metal objects
    private let decodeQueue = DispatchQueue(label: "afterscreen.decode", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let received = RateCounter()
    private let metrics = ProcessMetrics()
    private var statsTimer: DispatchSourceTimer?
    private var probeBytes = 0
    private var probeStart: Date?
    private var ended = false
    private var lastKeyRequest = Date.distantPast
    private var recentFailures: [Date] = []
    private let idleTimeout: TimeInterval
    private let inFlightLock = NSLock()
    private var inFlight = 0
    /// Starts at 0 and is signalled up: a semaphore released below its initial value traps
    private let frameSlots = DispatchSemaphore(value: 0)

    /// Tile and video frames read but not yet on screen
    static let maxFramesInFlight = 3

    var framesInFlight: Int {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight
    }

    public init(connection: Connection, hardware: Welcome, display: StreamDisplay, idleTimeout: TimeInterval = 4) {
        self.connection = connection
        self.hardware = hardware
        self.display = display
        self.idleTimeout = idleTimeout
        for _ in 0..<ReceiverSession.maxFramesInFlight { frameSlots.signal() }
    }

    private func frameStarted() {
        inFlightLock.lock()
        inFlight += 1
        inFlightLock.unlock()
    }

    private func frameFinished() {
        inFlightLock.lock()
        inFlight -= 1
        inFlightLock.unlock()
        frameSlots.signal()
    }

    /// Reader thread: a full screen pipeline stops reading, so TCP backpressure reaches the sender
    private func waitForFrameSlot(_ m: Message) {
        guard m.type == .tileFrame || m.type == .videoFrame else { return }
        while frameSlots.wait(timeout: .now() + 0.25) == .timedOut {
            if connection.isClosed { return }
        }
    }

    /// Stream sizes a sender may ask for
    static func isPlausible(_ c: StreamConfig) -> Bool {
        // Up to 8K, whose raw frame fits one message
        let width = 16...7680, height = 16...4320
        return width.contains(c.streamPixels.width) && height.contains(c.streamPixels.height)
            && c.streamPixels.width % 4 == 0 && c.streamPixels.height % 4 == 0
            && width.contains(c.sourcePoints.width) && height.contains(c.sourcePoints.height)
    }

    public func start() {
        connection.onMessage = { [weak self] m in self?.handle(m) }
        connection.onClose = { [weak self] reason in self?.finish(reason: reason) }
        connection.readGate = { [weak self] m in self?.waitForFrameSlot(m) }
        connection.start(queue: queue, idleTimeout: idleTimeout)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendStats() }
        timer.resume()
        statsTimer = timer
    }

    /// User-initiated stop
    public func stop(reason: String) {
        queue.async { [self] in
            if let bye = try? JSONWire.message(.bye, Bye(reason: reason)) { connection.send(bye) }
            connection.closeAfterFlush(reason: reason)
        }
    }

    private func handle(_ m: Message) {
        switch m.type {
        case .hello:
            guard let hello = try? JSONWire.decode(Hello.self, from: m.payload) else { return fail("bad hello") }
            peer = hello
            DispatchQueue.main.async { [weak self] in self?.onPeer?(hello) }
            send(.welcome, hardware)
            if hello.protocolVersion != AfterscreenProtocol.version {
                send(.bye, Bye(reason: "Protocol mismatch (sender \(hello.protocolVersion), receiver \(AfterscreenProtocol.version)): update both apps"))
                connection.closeAfterFlush(reason: "protocol mismatch")
            }
        case .config:
            guard let config = try? JSONWire.decode(StreamConfig.self, from: m.payload),
                  ReceiverSession.isPlausible(config) else { return fail("bad config") }
            self.config = config
            // Ordered ahead of every later decode-queue job (video parameters, tiles)
            decodeQueue.async { [weak self] in self?.display?.prepare(config: config) }
            DispatchQueue.main.async { [weak self] in self?.display?.begin(config: config) }
        case .tileFrame:
            frameStarted()
            guard let config = config, config.path == .tile else {
                frameFinished()
                return fail("tile frame without a tile stream")
            }
            let payload = m.payload
            let geometry = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
            decodeQueue.async { [weak self] in
                self?.decodeTiles(payload, expecting: geometry)
                self?.frameFinished()
            }
        case .videoParams:
            guard let params = try? VideoWire.parseParams(m.payload) else { return fail("bad video parameters") }
            decodeQueue.async { [weak self] in
                guard let self = self, let display = self.display else { return }
                if !display.setVideoParams(codec: params.codec, parameterSets: params.sets) {
                    self.queue.async { self.fail("video decoder unavailable for \(params.codec.rawValue)") }
                }
            }
        case .videoFrame:
            frameStarted()
            guard let frame = try? VideoWire.parseFrame(m.payload) else {
                frameFinished()
                return fail("bad video frame")
            }
            received.tick()
            decodeQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.frameFinished() }
                guard let display = self.display else { return }
                if !display.showVideoFrame(avcc: frame.avcc, keyframe: frame.keyframe) {
                    self.queue.async { self.decodeFailed() }
                }
            }
        case .cursorPos:
            guard let pos = try? CursorWire.parsePos(m.payload) else { return }
            DispatchQueue.main.async { [weak self] in self?.display?.cursor(x: pos.x, y: pos.y, visible: pos.visible) }
        case .cursorImage:
            guard let image = try? CursorWire.parseImage(m.payload) else { return }
            DispatchQueue.main.async { [weak self] in self?.display?.cursorImage(image) }
        case .probe:
            if probeStart == nil { probeStart = Date() }
            if m.flags & ProbeFlags.end != 0 {
                let seconds = max(1e-6, Date().timeIntervalSince(probeStart ?? Date()))
                send(.probeResult, ProbeResult(bytes: probeBytes, seconds: seconds))
                probeBytes = 0
                probeStart = nil
            } else {
                probeBytes += m.payload.count
            }
        case .ping:
            connection.send(Message(type: .pong, payload: m.payload))
        case .bye:
            let reason = (try? JSONWire.decode(Bye.self, from: m.payload))?.reason ?? "sender stopped"
            connection.close(reason: reason)
        case .welcome, .probeResult, .pong, .stats, .keyRequest:
            break
        }
    }

    private func decodeTiles(_ payload: Data, expecting geometry: TileGeometry) {
        do {
            let frame = try TileFrame(payload: payload, expecting: geometry)
            received.tick()
            if display?.showTiles(frame) == false {
                queue.async { [weak self] in self?.fail("tile data failed to decode") }
            }
        } catch {
            queue.async { [weak self] in self?.fail("bad tile frame: \(error)") }
        }
    }

    /// Asks for a keyframe; three failures within 10 s end the session
    private func decodeFailed() {
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 10 } + [now]
        if recentFailures.count >= 3 { return fail("video decoding keeps failing") }
        if now.timeIntervalSince(lastKeyRequest) > 0.5 {
            lastKeyRequest = now
            connection.send(Message(type: .keyRequest))
        }
    }

    private func sendStats() {
        guard !ended, let display = display else { return }
        let m = metrics.sample()
        let stats = ReceiverStats(receivedFPS: received.ratePerSecond(), displayedFPS: display.displayedFPS,
                                  uploadMs: display.uploadMs, decompressMs: display.decodeMs, lateFrames: display.lateFrames,
                                  cpuPercent: m.cpuPercent, memoryBytes: m.memoryBytes,
                                  gpuPercent: display.gpuMeter.percentSinceLastRead())
        send(.stats, stats)
    }

    private func send<T: Encodable>(_ type: MessageType, _ value: T) {
        guard let m = try? JSONWire.message(type, value) else { return }
        connection.send(m)
    }

    private func fail(_ reason: String) {
        send(.bye, Bye(reason: reason))
        connection.closeAfterFlush(reason: reason)
    }

    private func finish(reason: String) {
        guard !ended else { return }
        ended = true
        statsTimer?.cancel()
        statsTimer = nil
        decodeQueue.async { [weak self] in self?.display?.releaseDecodeResources() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.display?.end(reason: reason)
            self.onEnd?(reason)
        }
    }
}
