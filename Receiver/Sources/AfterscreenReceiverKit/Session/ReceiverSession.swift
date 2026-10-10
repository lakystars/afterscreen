import Foundation
import AfterscreenCore

/// Screen side of a session
/// Main queue: begin, end, cursor
/// Session's serial decode queue: showTiles and video calls
/// Hybrid: video frames only decode; the following tile frame presents
public protocol StreamDisplay: AnyObject {
    func begin(config: StreamConfig)
    /// Serial queue for decode and draw work
    /// Shared across sessions: one session's release precedes the next's frames
    var decodeQueue: DispatchQueue { get }
    /// Decode queue: drops the previous stream's decoder and texture state
    func prepare(config: StreamConfig)
    /// Decode queue, after session end: frees textures and staging buffers
    func releaseDecodeResources()
    /// Set by the session: requests `redraw` on its decode queue
    /// For example, a hidden stream showing again
    var onRedrawNeeded: (() -> Void)? { get set }
    /// Decode queue: draws the current picture again without new tiles
    func redraw()
    /// `relink`: sender reconnects at once; picture held for next session
    func end(reason: String, relink: Bool)
    /// false when the tile data fails to decode
    /// `present`: draw to the screen; else only update the texture
    /// `present` false when frames queue behind: refresh never limits intake
    func showTiles(_ frame: TileFrame, present: Bool) -> Bool
    /// false when the decoder cannot be created
    /// `tenBit`: decodes Main10 to 10-bit planes
    func setVideoParams(codec: VideoCodec, tenBit: Bool, parameterSets: [Data]) -> Bool
    /// false when the frame failed to decode
    func decodeVideo(avcc: Data) -> Bool
    func cursor(x: Float, y: Float, visible: Bool)
    func cursorImage(_ image: CursorImage)
    /// Panel brightness 0…1; nil when unreadable
    var brightness: Double? { get }
    /// Main queue
    func setBrightness(_ level: Double)
    /// Any queue
    func playAudio(_ packet: AudioWire.Packet)
    /// Main queue: output volume and mute follow the sender's
    /// nil returns the iMac's own level
    func followOutput(_ level: OutputLevel?)
    /// Any queue: smoothing of one-level steps, from the next draw
    func setDeband(_ level: Deband)
    /// Sound buffered for playback in seconds; nil while none plays
    var audioBuffered: Double? { get }
    var audioUnderruns: Int { get }
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
    /// Read on main by the HUD; written on session queue
    public var peer: Hello? {
        configLock.lock(); defer { configLock.unlock() }
        return currentPeer
    }
    /// Session queue
    private var currentPeer: Hello?
    /// The sender said it reconnects at once
    /// Read on main once the session has ended
    public var relinking: Bool { peerBye?.relink ?? false }
    /// The sender's bye, kept for its reason
    /// The close right after it reports only "closed by peer"
    private var peerBye: Bye?
    /// Read on main by the HUD; written on session queue
    public var config: StreamConfig? {
        configLock.lock(); defer { configLock.unlock() }
        return currentConfig
    }
    private let configLock = NSLock()
    private var currentConfig: StreamConfig?
    /// Read on main by the HUD; written on session queue
    public var telemetry: HUDTelemetry {
        telemetryLock.lock(); defer { telemetryLock.unlock() }
        return currentTelemetry
    }
    private let telemetryLock = NSLock()
    private var currentTelemetry = HUDTelemetry()

    private let connection: Connection
    /// Second connection for cursor and audio; never waits behind frames
    private var cursorChannel: Connection?
    private let channelToken = UInt32.random(in: 1...UInt32.max)
    private let hardware: Welcome
    private weak var display: StreamDisplay?
    private let queue = DispatchQueue(label: "afterscreen.session")
    private let decodeQueue: DispatchQueue
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
    /// Starts at 0 and is signalled up
    /// A semaphore deallocated below its initial value traps
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
        decodeQueue = display.decodeQueue
        self.idleTimeout = idleTimeout
        display.onRedrawNeeded = { [weak self] in self?.decodeQueue.async { self?.display?.redraw() } }
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

    /// Reader thread: blocks while the screen pipeline is full
    /// TCP backpressure then reaches the sender
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
    }

    public func start() {
        connection.onMessage = { [weak self] m in self?.handle(m) }
        connection.onClose = { [weak self] reason in self?.finish(reason: reason) }
        connection.readGate = { [weak self] m in self?.waitForFrameSlot(m) }
        connection.start(queue: queue, idleTimeout: idleTimeout)
        statsTimer = DispatchSource.repeating(on: queue, every: 1, after: 1) { [weak self] in self?.sendStats() }
    }

    /// User-initiated stop; `pause` asks the sender not to auto-reconnect
    public func stop(reason: String, pause: Bool = false) {
        queue.async { [self] in
            connection.send(.bye, json: Bye(reason: reason, pause: pause))
            connection.closeAfterFlush(reason: reason)
        }
    }

    private func handle(_ m: Message) {
        switch m.type {
        case .hello:
            guard let hello = try? JSONWire.decode(Hello.self, from: m.payload) else { return fail("bad hello") }
            configLock.lock()
            currentPeer = hello
            configLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onPeer?(hello) }
            var welcome = hardware
            welcome.channelToken = channelToken
            connection.send(.welcome, json: welcome)
            if hello.protocolVersion != AfterscreenProtocol.version {
                connection.send(.bye, json: Bye(reason: "Protocol mismatch (sender \(hello.protocolVersion), receiver \(AfterscreenProtocol.version)): update both apps"))
                connection.closeAfterFlush(reason: "protocol mismatch")
            }
        case .config:
            guard let config = try? JSONWire.decode(StreamConfig.self, from: m.payload),
                  ReceiverSession.isPlausible(config) else { return fail("bad config") }
            configLock.lock()
            currentConfig = config
            configLock.unlock()
            // Ordered ahead of every later decode-queue job (video parameters, tiles)
            decodeQueue.async { [weak self] in self?.display?.prepare(config: config) }
            DispatchQueue.main.async { [weak self] in self?.display?.begin(config: config) }
        case .tileFrame:
            frameStarted()
            guard let config = config else {
                frameFinished()
                return fail("tile frame before the stream config")
            }
            let payload = m.payload
            let geometry = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
            decodeQueue.async { [weak self] in
                self?.decodeTiles(payload, expecting: geometry)
                self?.frameFinished()
            }
        case .videoParams:
            guard config?.path == .hybrid else { return fail("video without a hybrid stream") }
            guard let params = try? VideoWire.parseParams(m.payload) else { return fail("bad video parameters") }
            let tenBit = config?.video?.tenBit ?? false
            decodeQueue.async { [weak self] in
                guard let self = self, let display = self.display else { return }
                if !display.setVideoParams(codec: params.codec, tenBit: tenBit, parameterSets: params.sets) {
                    self.queue.async { self.fail("video decoder unavailable for \(params.codec.rawValue)") }
                }
            }
        case .videoFrame:
            frameStarted()
            guard config?.path == .hybrid, let frame = try? VideoWire.parseFrame(m.payload) else {
                frameFinished()
                return fail("video frame without a hybrid stream")
            }
            decodeQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.frameFinished() }
                guard let display = self.display else { return }
                if !display.decodeVideo(avcc: frame.avcc) {
                    self.queue.async { self.decodeFailed() }
                }
            }
        case .cursorPos, .cursorImage:
            cursor(m)
        case .audio:
            audio(m)
        case .volume:
            volume(m)
        case .deband:
            guard currentPeer != nil, let level = try? DebandWire.decode(m.payload) else { return }
            record { $0.deband = level }
            display?.setDeband(level)
        case .senderStats:
            guard currentPeer != nil, let stats = try? JSONWire.decode(SenderStats.self, from: m.payload) else { return }
            record {
                $0.sender = stats
                $0.throughput.push(stats.throughputBitsPerSecond)
                if let ms = stats.latencyMs { $0.latency.push(ms) }
            }
        case .brightness:
            guard currentPeer != nil, let level = try? LevelWire.decode(m.payload) else { return }
            DispatchQueue.main.async { [weak self] in self?.display?.setBrightness(level) }
        case .probe:
            if probeStart == nil { probeStart = Date() }
            if m.flags & ProbeFlags.end != 0 {
                let seconds = max(1e-6, Date().timeIntervalSince(probeStart ?? Date()))
                connection.send(.probeResult, json: ProbeResult(bytes: probeBytes, seconds: seconds))
                probeBytes = 0
                probeStart = nil
            } else {
                probeBytes += m.payload.count
            }
        case .ping:
            connection.send(Message(type: .pong, payload: m.payload))
        case .bye:
            let bye = (try? JSONWire.decode(Bye.self, from: m.payload)) ?? Bye(reason: "sender stopped")
            peerBye = bye
            connection.close(reason: bye.reason)
        case .welcome, .probeResult, .pong, .stats, .keyRequest, .cursorChannel:
            break
        }
    }

    /// Usually on the cursor channel, ahead of the sound
    private func volume(_ m: Message) {
        // `try?` would fold the nil release into a decode failure
        guard currentPeer != nil, case .success(let level) = Result(catching: { try OutputLevelWire.decode(m.payload) }) else { return }
        DispatchQueue.main.async { [weak self] in self?.display?.followOutput(level) }
    }

    private func audio(_ m: Message) {
        guard currentPeer != nil, let packet = try? AudioWire.decode(m.payload) else { return }
        display?.playAudio(packet)
    }

    private func cursor(_ m: Message) {
        if m.type == .cursorPos, let pos = try? CursorWire.parsePos(m.payload) {
            DispatchQueue.main.async { [weak self] in self?.display?.cursor(x: pos.x, y: pos.y, visible: pos.visible) }
        } else if m.type == .cursorImage, let image = try? CursorWire.parseImage(m.payload) {
            DispatchQueue.main.async { [weak self] in self?.display?.cursorImage(image) }
        }
    }

    /// Any queue: a connection made during the session
    /// First message with this session's token: becomes the cursor channel
    /// Anything else is refused as busy
    public func offerChannel(_ c: Connection) {
        c.onMessage = { [weak self, weak c] m in
            guard let self = self, let c = c else { return }
            guard self.cursorChannel === c else { return self.adopt(c, first: m) }
            if m.type == .cursorPos || m.type == .cursorImage { self.cursor(m) }
            if m.type == .audio { self.audio(m) }
            if m.type == .volume { self.volume(m) }
        }
        c.start(queue: queue)
        // Closes a connection that never presents the token
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak c] in
            guard let self = self, let c = c, self.cursorChannel !== c else { return }
            c.close(reason: "no cursor channel token")
        }
    }

    private func adopt(_ c: Connection, first m: Message) {
        guard !ended, cursorChannel == nil, m.type == .cursorChannel, (try? ChannelWire.decode(m.payload)) == channelToken else {
            c.send(.bye, json: Bye(reason: "Receiver is busy with another sender"))
            c.closeAfterFlush(reason: "busy")
            return
        }
        cursorChannel = c
    }

    private func decodeTiles(_ payload: Data, expecting geometry: TileGeometry) {
        do {
            let frame = try TileFrame(payload: payload, expecting: geometry)
            received.tick()
            if display?.showTiles(frame, present: framesInFlight <= 1) == false {
                queue.async { [weak self] in self?.fail("tile data failed to decode") }
            }
        } catch {
            queue.async { [weak self] in self?.fail("bad tile frame: \(error)") }
        }
    }

    /// Requests a keyframe
    /// Three failures within 10 s end the session
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
                                  gpuPercent: display.gpuMeter.percentSinceLastRead(), brightness: display.brightness,
                                  audioBufferMs: display.audioBuffered.map { $0 * 1000 },
                                  audioUnderruns: display.audioUnderruns)
        record {
            $0.receiver = stats
            $0.shownFPS.push(stats.displayedFPS)
        }
        connection.send(.stats, json: stats)
    }

    private func record(_ change: (inout HUDTelemetry) -> Void) {
        telemetryLock.lock()
        change(&currentTelemetry)
        telemetryLock.unlock()
    }

    private func fail(_ reason: String) {
        connection.send(.bye, json: Bye(reason: reason))
        connection.closeAfterFlush(reason: reason)
    }

    private func finish(reason: String) {
        guard !ended else { return }
        ended = true
        let reason = peerBye?.reason ?? reason
        let relink = relinking
        statsTimer?.cancel()
        statsTimer = nil
        cursorChannel?.close(reason: reason)
        cursorChannel = nil
        // Captures the display, not the session
        // App may drop the session at onEnd before this runs
        decodeQueue.async { [display] in display?.releaseDecodeResources() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.display?.end(reason: reason, relink: relink)
            self.onEnd?(reason)
        }
    }
}
