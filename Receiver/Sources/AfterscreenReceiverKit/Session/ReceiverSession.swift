import CryptoKit
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
    /// Main queue: power-off over the live stream
    /// `done` once black; `end` then closes at once
    func powerOff(done: @escaping () -> Void)
    /// false when the tile data fails to decode
    /// `present`: draw to the screen; else only update the texture
    /// `present` false when frames queue behind: refresh never limits intake
    /// `refinement`: settled blocks sent again sharper
    func showTiles(_ frame: TileFrame, present: Bool, refinement: Bool) -> Bool
    /// false when the decoder cannot be created
    /// `tenBit`: decodes Main10 to 10-bit planes
    func setVideoParams(codec: VideoCodec, tenBit: Bool, parameterSets: [Data]) -> Bool
    /// false when the frame failed to decode
    func decodeVideo(avcc: Data) -> Bool
    func cursor(x: Float, y: Float, visible: Bool)
    func cursorImage(_ image: CursorImage)
    /// Main queue
    /// Matches the sender's nits on this panel when it can
    func setBrightness(_ light: PanelLight)
    /// The stream's screen, 0…1; nil when unreadable
    var panelLevel: Double? { get }
    /// Main queue: the sender lowered quality for congestion
    func showCongestionNotice(wifi: Bool)
    /// Any queue
    func playAudio(_ packet: AudioWire.Packet)
    /// Main queue: output volume and mute follow the sender's
    /// nil returns the iMac's own level
    func followOutput(_ level: OutputLevel?)
    /// Any queue: smoothing of one-level steps, from the next draw
    func setDeband(_ level: Deband)
    /// Any queue: debug tint of arriving blocks, sender's choice
    func setFlashBlocks(_ on: Bool)
    /// Main queue: the stream went quiet, or came back
    /// `detail`: why, when known
    func linkWaiting(_ waiting: Bool, detail: String?)
    /// Sound buffered for playback in seconds; nil while none plays
    var audioBuffered: Double? { get }
    var audioUnderruns: Int { get }
    var gpuMeter: GPUTimeMeter { get }
    var displayedFPS: Double { get }
    /// Stream picture powered on and on screen
    var isShown: Bool { get }
    var lateFrames: Int { get }
    var uploadMs: Double { get }
    var decodeMs: Double { get }
}

/// Pairing demand of one connection
public struct ReceiverAuth {
    public var receiverID: String
    /// Networks with paired-only on; point-to-point cables skip it
    /// A paired Mac proves its key whatever the link
    public var required: Bool
    public var store: PairingStoring
    public var limiter: PairingLimiter
    /// Main queue: the code for a sender; nil hides it
    public var onCode: (String?, String) -> Void
    /// Unaccepted connections close then: no slot held for long
    public var proofTimeout: TimeInterval = 10
    /// The user types the code meanwhile
    public var codeTimeout: TimeInterval = 90

    public init(receiverID: String, required: Bool, store: PairingStoring, limiter: PairingLimiter,
                onCode: @escaping (String?, String) -> Void) {
        self.receiverID = receiverID
        self.required = required
        self.store = store
        self.limiter = limiter
        self.onCode = onCode
    }
}

/// Five wrong codes lock pairing; locks double up to a day
/// Guesses at a 1-in-a-million code: a few a day
public final class PairingLimiter {
    static let attempts = 5
    static let firstLock: TimeInterval = 600
    static let longestLock: TimeInterval = 86_400
    private var failures = 0
    private var locks = 0
    private var lockedUntil = Date.distantPast
    private let lock = NSLock()

    public init() {}

    public var locked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < lockedUntil
    }

    func failed() {
        lock.lock()
        failures += 1
        if failures >= PairingLimiter.attempts {
            failures = 0
            lockedUntil = Date().addingTimeInterval(min(PairingLimiter.longestLock, PairingLimiter.firstLock * pow(2, Double(locks))))
            locks += 1
        }
        lock.unlock()
    }

    func succeeded() {
        lock.lock()
        failures = 0
        locks = 0
        lockedUntil = .distantPast
        lock.unlock()
    }
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
    /// Main queue: the current link is a point-to-point cable
    public var cable = false
    /// Main queue: admitted with a proven pairing key
    public private(set) var keyed = false
    /// Main queue: the sender's edits are heeded
    /// A proven key or a cable, as for power requests
    public var trusted: Bool { keyed || cable }
    /// Main queue: a trusted sender's settings edit
    public var onOptionsChange: ((ReceiverOptionsChange) -> Void)?
    /// Main queue: the sender shows another language
    public var onLanguage: ((Language) -> Void)?
    /// Session queue: last language the sender reported
    private var senderLanguage: Language?
    /// Session queue: the sender's hello takes `receiverOptions`
    private var readsOptions = false
    /// Sender's power request, from a proven key or cable
    /// Read on main once the session has ended
    public var powerRequest: ReceiverPower? { sessionKey != nil || cable ? askedPower : nil }
    /// As sent, trusted or not: for the log
    public var askedPower: ReceiverPower? { peerBye?.power }
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

    /// Session queue; a handover replaces it
    private var connection: Connection
    /// Second connection for cursor and audio; never waits behind frames
    private var cursorChannel: Connection?
    private let channelToken = UInt32.random(in: 1...UInt32.max)
    /// Proven by a connection taking the session over
    private let handoverToken = Pairing.nonce()
    /// Pairing key the sender proved; nil when admitted without one
    private var sessionKey: Data?
    private struct PendingHandover {
        let connection: Connection
        let senderNonce: Data
        let receiverNonce: Data
        let secret: SymmetricKey
    }
    /// Connections proving the handover secret
    /// One each: a stranger cannot block the real sender
    private var handovers: [ObjectIdentifier: PendingHandover] = [:]
    /// Proven; carries the session once `switchover` arrives
    private var takeover: Connection?
    /// After a switchover: the sender reopens its cursor channel
    private var cursorReplaceable = false
    /// Main connection lost without a bye: held for a resume
    private var suspended: String?
    /// Ended on this side: its own close is no loss
    private var leaving = false
    /// How long a lost link may take to come back
    private let resumeWait: TimeInterval
    /// Silent this long: a new sender's hello replaces it
    private let staleAfter: TimeInterval
    /// Last message on the main connection; under `configLock`
    private var lastHeard = ProcessInfo.processInfo.systemUptime
    /// Quiet past `quietAfter`, or link down: the screen shows it
    private var waiting = false
    static let quietAfter: TimeInterval = 1
    /// Media checks in a row finding this side's link down
    private var downChecks = 0
    private var watchTimer: DispatchSourceTimer?
    /// As long as the window holds a relinking picture
    public static let resumeWait = StreamWindow.relinkWait
    /// What a new connection's link needs; nil refuses handovers
    public var admission: ((Connection) -> LinkAdmission)?
    /// Main queue, after a handover: the new main connection
    public var onHandover: ((Connection) -> Void)?

    public enum LinkAdmission: Equatable {
        case refused(String)
        /// A cable on its own interface, or pairing off
        case open
        case pairing
    }
    private let hardware: Welcome
    private let auth: ReceiverAuth?
    /// Session queue: a hello waiting on its proof or pairing
    private var pendingHello: Hello?
    private var receiverNonce = Data()
    private var pairing: (key: Pairing.PrivateKey, code: String)?
    /// The challenge sent; only its answer is taken
    private var issued: AuthChallenge.Mode?
    /// Unaccepted after a challenge, or on a pairing link
    private var gated: Bool { currentPeer == nil && (issued != nil || auth?.required == true) }
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

    /// `auth`: nil or not required streams without pairing
    public init(connection: Connection, hardware: Welcome, display: StreamDisplay, idleTimeout: TimeInterval = 4, auth: ReceiverAuth? = nil,
                resumeWait: TimeInterval = ReceiverSession.resumeWait, staleAfter: TimeInterval = 3) {
        self.connection = connection
        self.resumeWait = resumeWait
        self.staleAfter = staleAfter
        self.hardware = hardware
        self.auth = auth
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
    private func waitForFrameSlot(_ m: Message, on c: Connection) {
        guard m.type == .tileFrame || m.type == .videoFrame else { return }
        while frameSlots.wait(timeout: .now() + 0.25) == .timedOut {
            if c.isClosed { return }
        }
    }

    /// Stream sizes a sender may ask for
    static func isPlausible(_ c: StreamConfig) -> Bool {
        // Up to 8K, whose raw frame fits one message
        let width = 16...7680, height = 16...4320
        return width.contains(c.streamPixels.width) && height.contains(c.streamPixels.height)
            && c.streamPixels.width % 4 == 0 && c.streamPixels.height % 4 == 0 && (1...480).contains(c.frameRate)
    }

    public func start() {
        bind(connection)
        connection.start(queue: queue, idleTimeout: idleTimeout)
        statsTimer = DispatchSource.repeating(on: queue, every: 1, after: 1) { [weak self] in self?.sendStats() }
        watchTimer = DispatchSource.repeating(on: queue, every: 0.25, after: 0.25) { [weak self] in self?.watchLink() }
    }

    /// Session queue: tells the screen a link went quiet
    /// The sender pings twice a second, even when still
    private func watchLink() {
        guard !ended, currentPeer != nil, let config = config, !config.test else { return }
        configLock.lock()
        let quiet = ProcessInfo.processInfo.systemUptime - lastHeard
        configLock.unlock()
        let down = connection.localInterfaceName.map { Interfaces.isActive($0) == false } ?? false
        downChecks = down ? downChecks + 1 : 0
        let unplugged = downChecks >= 2
        let lost = suspended != nil || unplugged || quiet > ReceiverSession.quietAfter
        guard lost != waiting else { return }
        waiting = lost
        let detail = unplugged ? L10n.t("\(LinkLabel.name(config.linkKind)) disconnected; finding another link",
                                        "\(LinkLabel.name(config.linkKind)) 연결이 끊겨 다른 링크를 찾는 중") : nil
        DispatchQueue.main.async { [weak self] in self?.display?.linkWaiting(lost, detail: detail) }
    }

    /// A replaced connection's close ends nothing
    private func bind(_ c: Connection) {
        c.onMessage = { [weak self] m in self?.handle(m) }
        c.onClose = { [weak self, weak c] reason in
            guard let self = self, self.connection === c else { return }
            self.connectionLost(reason)
        }
        c.readGate = { [weak self, weak c] m in
            guard let c = c else { return }
            self?.waitForFrameSlot(m, on: c)
        }
    }

    /// A streaming sender gone without a bye may come back
    /// Over another link, within `resumeWait`; else the session ends
    private func connectionLost(_ reason: String) {
        guard peerBye == nil, !leaving, currentPeer != nil, let config = config, !config.test, !ended else { return finish(reason: reason) }
        guard suspended == nil else { return }
        suspended = reason
        queue.asyncAfter(deadline: .now() + resumeWait) { [weak self] in
            // No link came back: black tiles close in
            guard let self = self, let reason = self.suspended else { return }
            self.finish(reason: reason)
        }
    }

    /// Streaming, but nothing heard for `staleAfter`
    private var isStale: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return currentPeer != nil && currentConfig != nil && ProcessInfo.processInfo.systemUptime - lastHeard > staleAfter
    }

    /// The sender ends its resume and starts anew
    private func noSession(_ c: Connection) {
        c.send(.bye, json: Bye(reason: L10n.t("No session to resume", "이어 갈 세션이 없습니다")))
        c.closeAfterFlush(reason: "no session to resume")
    }

    /// Session queue: ends for the sender's next connection
    /// Picture held; the bye asks it back at once
    private func giveWay(to c: Connection) {
        let reason = L10n.t("The sender connected again", "송신기가 다시 연결했습니다")
        c.send(.bye, json: Bye(reason: reason, relink: true))
        c.closeAfterFlush(reason: reason)
        guard !ended else { return }
        if peerBye == nil { peerBye = Bye(reason: reason, relink: true) }
        leaving = true
        connection.close(reason: reason)
        finish(reason: reason)
    }

    /// User-initiated stop; `pause` asks the sender not to auto-reconnect
    public func stop(reason: String, pause: Bool = false) {
        queue.async { [self] in
            leaving = true
            // Waiting for a lost sender: no connection to close
            if suspended != nil { return finish(reason: reason) }
            connection.send(.bye, json: Bye(reason: reason, pause: pause))
            connection.closeAfterFlush(reason: reason)
        }
    }

    private func handle(_ m: Message) {
        configLock.lock()
        lastHeard = ProcessInfo.processInfo.systemUptime
        configLock.unlock()
        // Resume of a session gone here: start anew
        if m.type == .handover, currentPeer == nil { return noSession(connection) }
        // Challenged or pairing link: only the handshake until accepted
        guard !gated || [.hello, .auth, .pair, .ping, .bye].contains(m.type) else {
            if m.type == .tileFrame || m.type == .videoFrame { frameSlots.signal() }
            return
        }
        switch m.type {
        case .hello:
            guard currentPeer == nil, pendingHello == nil, let hello = try? JSONWire.decode(Hello.self, from: m.payload) else { return fail("bad hello") }
            var welcome = hardware
            welcome.channelToken = channelToken
            welcome.handoverToken = handoverToken
            welcome.receiverID = auth?.receiverID
            if hello.protocolVersion != AfterscreenProtocol.version {
                connection.send(.welcome, json: welcome)
                connection.send(.bye, json: Bye(reason: "Protocol mismatch (sender \(hello.protocolVersion), receiver \(AfterscreenProtocol.version)): update both apps"))
                return connection.closeAfterFlush(reason: "protocol mismatch")
            }
            // A Mac claiming a key proves it on cables too
            // Key gone here, or its proof failed: a code instead
            let wantsCode = hello.repair == true
            let known = hello.paired == true && !wantsCode && hello.senderID.map { auth?.store.key(for: $0) != nil } == true
            guard let auth = auth, auth.required || hello.paired == true || wantsCode else {
                connection.send(.welcome, json: welcome)
                return accept(hello)
            }
            guard hello.senderID != nil, hello.nonce != nil else { return fail("pairing needs the sender's identity") }
            pendingHello = hello
            receiverNonce = Pairing.nonce()
            if known {
                issued = .paired
                welcome.auth = AuthChallenge(mode: .paired, nonce: receiverNonce)
            } else {
                guard !auth.limiter.locked else { return fail(lockedReason) }
                let key = Pairing.newKey(), code = Pairing.code()
                pairing = (key, code)
                issued = .pair
                welcome.auth = AuthChallenge(mode: .pair, nonce: receiverNonce, publicKey: key.publicKey.rawRepresentation)
                DispatchQueue.main.async { auth.onCode(code, hello.name) }
            }
            connection.send(.welcome, json: welcome)
            queue.asyncAfter(deadline: .now() + (issued == .pair ? auth.codeTimeout : auth.proofTimeout)) { [weak self] in
                guard let self = self, !self.ended, self.currentPeer == nil else { return }
                self.fail(L10n.t("Pairing timed out", "페어링 시간이 지났습니다"))
            }
        case .auth:
            guard issued == .paired, let hello = pendingHello, let auth = auth, let senderID = hello.senderID, let senderNonce = hello.nonce,
                  let key = auth.store.key(for: senderID), let proof = try? JSONWire.decode(AuthProof.self, from: m.payload) else { return }
            let t = Pairing.Transcript(senderID: senderID, receiverID: auth.receiverID, senderNonce: senderNonce, receiverNonce: receiverNonce)
            guard Pairing.matches(proof.mac, Pairing.proof(key: key, role: .sender, transcript: t)) else {
                // Key kept: anyone can claim this sender's ID
                // The real sender drops its key and pairs afresh
                return fail(L10n.t("The pairing no longer matches; connect again to pair", "페어링 정보가 맞지 않습니다. 다시 연결해 페어링하세요"), repair: true)
            }
            connection.send(.authOK, json: AuthProof(mac: Pairing.proof(key: key, role: .receiver, transcript: t)))
            pendingHello = nil
            sessionKey = key
            accept(hello)
        case .pair:
            guard issued == .pair, let hello = pendingHello, let auth = auth, let senderID = hello.senderID, let senderNonce = hello.nonce,
                  let (key, code) = pairing, let confirm = try? JSONWire.decode(PairConfirm.self, from: m.payload) else { return }
            let t = Pairing.Transcript(senderID: senderID, receiverID: auth.receiverID, senderNonce: senderNonce, receiverNonce: receiverNonce,
                                       senderKey: confirm.publicKey, receiverKey: key.publicKey.rawRepresentation)
            guard let session = try? Pairing.sessionKey(key, peer: confirm.publicKey, transcript: t),
                  Pairing.matches(confirm.mac, Pairing.confirm(session, code: code, transcript: t)) else {
                auth.limiter.failed()
                guard !auth.limiter.locked else { return fail(lockedReason) }
                // Same code stays up for another try
                return connection.send(Message(type: .pairWrong))
            }
            pairing = nil
            DispatchQueue.main.async { auth.onCode(nil, hello.name) }
            auth.limiter.succeeded()
            let kept = Pairing.pairingKey(session, code: code, transcript: t)
            guard auth.store.save(kept, for: senderID, name: hello.name) else {
                return fail(L10n.t("\(hardware.name) could not keep the pairing", "\(hardware.name)에 페어링을 저장하지 못했습니다"))
            }
            connection.send(.paired, json: AuthProof(mac: Pairing.pairedProof(session, transcript: t)))
            pendingHello = nil
            sessionKey = kept
            accept(hello)
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
            let payload = m.payload, refinement = m.flags & TileFlags.refinement != 0
            let geometry = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
            decodeQueue.async { [weak self] in
                self?.decodeTiles(payload, expecting: geometry, refinement: refinement)
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
            display?.setFlashBlocks(stats.flashBlocks == true)
            // Its user reads this screen too; unknown ones ignored
            if let language = stats.language.flatMap(Language.init(rawValue:)), language != .system, language != senderLanguage {
                senderLanguage = language
                DispatchQueue.main.async { [weak self] in self?.onLanguage?(language) }
            }
            if stats.congestionNotice == true {
                let wifi = config?.linkKind == .wifi
                DispatchQueue.main.async { [weak self] in self?.display?.showCongestionNotice(wifi: wifi) }
            }
        case .brightness:
            guard currentPeer != nil, let light = try? BrightnessWire.decode(m.payload) else { return }
            DispatchQueue.main.async { [weak self] in self?.display?.setBrightness(light) }
        case .setReceiverOptions:
            guard currentPeer != nil, let change = try? JSONWire.decode(ReceiverOptionsChange.self, from: m.payload) else { return }
            let keyed = sessionKey != nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard keyed || self.cable else {
                    return FileHandle.standardError.write(Data("[receiver] Ignored a settings edit: no pairing key or cable\n".utf8))
                }
                self.onOptionsChange?(change)
            }
        case .probe:
            probe(m, on: connection)
        case .reconfigure:
            // Same size only: the picture and its tiles stay
            guard let next = try? JSONWire.decode(StreamConfig.self, from: m.payload), ReceiverSession.isPlausible(next),
                  next.streamPixels == config?.streamPixels else { return fail("bad reconfigure") }
            configLock.lock()
            currentConfig = next
            configLock.unlock()
        case .ping:
            connection.send(Message(type: .pong, payload: m.payload))
        case .bye:
            var bye = (try? JSONWire.decode(Bye.self, from: m.payload)) ?? Bye(reason: "sender stopped")
            // A slow power-off's fallback bye keeps its request
            bye.power = bye.power ?? peerBye?.power
            peerBye = bye
            connection.close(reason: bye.reason)
        case .powerOff:
            guard currentPeer != nil else { return }
            let bye = (try? JSONWire.decode(Bye.self, from: m.payload)) ?? Bye(reason: "sender stopped")
            peerBye = bye
            // Picture and sound live until black; bye ends both
            DispatchQueue.main.async { [weak self] in
                self?.display?.powerOff { self?.stop(reason: bye.reason) }
            }
        case .switchover:
            switchOver()
        case .welcome, .probeResult, .pong, .stats, .keyRequest, .cursorChannel, .authOK, .paired, .pairWrong,
             .handover, .handoverChallenge, .handoverProof, .handoverOK, .receiverOptions:
            break
        }
    }

    /// The old connection's last message: the proven one takes over
    /// Its echo tells the sender frames may follow there
    private func switchOver() {
        guard let next = takeover, !ended else { return }
        takeover = nil
        // Gone meanwhile: stay; the sender relinks or ends
        guard !next.isClosed else { return }
        let old = connection
        connection = next
        bind(next)
        next.watchIdle(idleTimeout)
        next.send(Message(type: .switchover))
        cursorReplaceable = true
        suspended = nil
        old.closeAfterFlush(reason: "handed over")
        DispatchQueue.main.async { [weak self] in self?.onHandover?(next) }
    }

    /// Measures the link `c` runs over; answers there
    private func probe(_ m: Message, on c: Connection) {
        if probeStart == nil { probeStart = Date() }
        if m.flags & ProbeFlags.end != 0 {
            let seconds = max(1e-6, Date().timeIntervalSince(probeStart ?? Date()))
            c.send(.probeResult, json: ProbeResult(bytes: probeBytes, seconds: seconds))
            probeBytes = 0
            probeStart = nil
        } else {
            probeBytes += m.payload.count
        }
    }

    /// Session queue: link of the main connection, for the HUD
    public func linkChanged(to kind: LinkKind) {
        queue.async { [self] in
            configLock.lock()
            currentConfig?.linkKind = kind
            configLock.unlock()
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
        guard !gated else { return }
        if m.type == .cursorPos, let pos = try? CursorWire.parsePos(m.payload) {
            DispatchQueue.main.async { [weak self] in self?.display?.cursor(x: pos.x, y: pos.y, visible: pos.visible) }
        } else if m.type == .cursorImage, let image = try? CursorWire.parseImage(m.payload) {
            DispatchQueue.main.async { [weak self] in self?.display?.cursorImage(image) }
        }
    }

    /// Any queue: a connection made during the session
    /// First message with this session's token: becomes the cursor channel
    /// A handover proving the session secret: may take it over
    /// Anything else is refused as busy
    public func offerChannel(_ c: Connection) {
        c.onMessage = { [weak self, weak c] m in
            guard let self = self, let c = c else { return }
            if self.cursorChannel === c {
                if m.type == .cursorPos || m.type == .cursorImage { self.cursor(m) }
                if m.type == .audio { self.audio(m) }
                if m.type == .volume { self.volume(m) }
                return
            }
            if let pending = self.handovers[ObjectIdentifier(c)] { return self.proveHandover(m, pending) }
            // Proven: its link is measured before the switch
            // A switchover here: the old link is gone
            if self.takeover === c {
                if m.type == .probe { self.probe(m, on: c) }
                if m.type == .switchover { self.switchOver() }
                return
            }
            // No side channel before the peer is accepted
            self.gated ? c.close(reason: "not accepted") : self.adopt(c, first: m)
        }
        c.onClose = { [weak self, weak c] _ in
            guard let self = self, let c = c else { return }
            self.handovers[ObjectIdentifier(c)] = nil
            if self.takeover === c { self.takeover = nil }
            if self.cursorChannel === c { self.cursorChannel = nil }
        }
        // Read once at start: a takeover's frames need backpressure
        c.readGate = { [weak self, weak c] m in
            guard let c = c else { return }
            self?.waitForFrameSlot(m, on: c)
        }
        c.start(queue: queue)
        // Closes a connection with no token or proof in time
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak c] in
            guard let self = self, let c = c, self.cursorChannel !== c, self.takeover !== c, self.connection !== c else { return }
            self.handovers[ObjectIdentifier(c)] = nil
            c.close(reason: "no cursor channel token or handover proof")
        }
    }

    /// A silent session still takes its sender's resume
    /// One under way keeps it from another sender
    private func adopt(_ c: Connection, first m: Message) {
        if ended, m.type == .handover { return noSession(c) }
        if ended || m.type == .hello && isStale && handovers.isEmpty && takeover == nil { return giveWay(to: c) }
        if m.type == .handover { return askHandover(c, m) }
        // A second channel only right after a handover
        guard m.type == .cursorChannel, (try? ChannelWire.decode(m.payload)) == channelToken, cursorChannel == nil || cursorReplaceable else {
            c.send(.bye, json: Bye(reason: "Receiver is busy with another sender"))
            c.closeAfterFlush(reason: "busy")
            return
        }
        cursorReplaceable = false
        cursorChannel?.close(reason: "replaced")
        cursorChannel = c
    }

    /// Same admission as a session over that link
    /// No pairing key: only a link that needs no pairing
    private func askHandover(_ c: Connection, _ m: Message) {
        let refuse = { (reason: String) in
            c.send(.bye, json: Bye(reason: reason))
            c.closeAfterFlush(reason: reason)
        }
        guard handovers.count < 4, let request = try? JSONWire.decode(HandoverNonce.self, from: m.payload),
              request.nonce.count == 16 else {
            return refuse("handover refused")
        }
        switch admission?(c) ?? .refused("handover refused") {
        case .refused(let reason):
            return refuse(reason)
        case .pairing where sessionKey == nil:
            return refuse(L10n.t("This link needs pairing", "이 링크는 페어링이 필요합니다"))
        case .open, .pairing:
            let nonce = Pairing.nonce()
            handovers[ObjectIdentifier(c)] = PendingHandover(connection: c, senderNonce: request.nonce, receiverNonce: nonce,
                                                             secret: Handover.secret(key: sessionKey, token: handoverToken))
            c.send(.handoverChallenge, json: HandoverNonce(nonce: nonce))
        }
    }

    private func proveHandover(_ m: Message, _ h: PendingHandover) {
        guard m.type == .handoverProof else { return }
        handovers[ObjectIdentifier(h.connection)] = nil
        let expected = Handover.proof(h.secret, role: .sender, senderNonce: h.senderNonce, receiverNonce: h.receiverNonce)
        guard let proof = try? JSONWire.decode(AuthProof.self, from: m.payload), Pairing.matches(proof.mac, expected) else {
            h.connection.send(.bye, json: Bye(reason: "handover proof did not match"))
            return h.connection.closeAfterFlush(reason: "bad handover proof")
        }
        // One takeover at a time: a dead earlier one goes
        takeover?.close(reason: "replaced")
        takeover = h.connection
        // A takeover lost mid-probe leaves no count behind
        probeBytes = 0
        probeStart = nil
        h.connection.send(.handoverOK, json: AuthProof(mac: Handover.proof(h.secret, role: .receiver, senderNonce: h.senderNonce,
                                                                           receiverNonce: h.receiverNonce)))
    }

    private func decodeTiles(_ payload: Data, expecting geometry: TileGeometry, refinement: Bool) {
        do {
            let frame = try TileFrame(payload: payload, expecting: geometry)
            received.tick()
            if display?.showTiles(frame, present: framesInFlight <= 1, refinement: refinement) == false {
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
        // An unaccepted peer learns nothing of this Mac
        guard !ended, !gated, let display = display else { return }
        let m = metrics.sample()
        let stats = ReceiverStats(receivedFPS: received.ratePerSecond(), displayedFPS: display.displayedFPS,
                                  uploadMs: display.uploadMs, decompressMs: display.decodeMs, lateFrames: display.lateFrames,
                                  cpuPercent: m.cpuPercent, memoryBytes: m.memoryBytes,
                                  gpuPercent: display.gpuMeter.percentSinceLastRead(),
                                  audioBufferMs: display.audioBuffered.map { $0 * 1000 },
                                  audioUnderruns: display.audioUnderruns, panelLevel: display.panelLevel,
                                  shown: display.isShown)
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

    /// Session queue: the sender may stream from here on
    private func accept(_ hello: Hello) {
        configLock.lock()
        currentPeer = hello
        configLock.unlock()
        readsOptions = hello.readsOptions == true
        let keyed = sessionKey != nil
        DispatchQueue.main.async { [weak self] in
            self?.keyed = keyed
            self?.onPeer?(hello)
        }
    }

    /// Any queue: current settings, to a sender that reads them
    public func send(_ options: ReceiverOptions) {
        queue.async { [self] in
            guard readsOptions, !ended, suspended == nil else { return }
            connection.send(.receiverOptions, json: options)
        }
    }

    /// Ends for settings that take a new window
    /// The bye brings the sender back at once
    public func reopen(reason: String) {
        queue.async { [self] in
            leaving = true
            if suspended != nil { return finish(reason: reason) }
            connection.send(.bye, json: Bye(reason: reason, relink: true, reopen: true))
            connection.closeAfterFlush(reason: reason)
        }
    }

    private var lockedReason: String {
        L10n.t("Too many wrong codes on \(hardware.name); try again in a few minutes",
               "\(hardware.name)에서 코드를 여러 번 틀렸습니다. 몇 분 뒤에 다시 시도하세요")
    }

    private func fail(_ reason: String, repair: Bool? = nil) {
        leaving = true
        if suspended != nil { return finish(reason: reason) }
        connection.send(.bye, json: Bye(reason: reason, repair: repair))
        connection.closeAfterFlush(reason: reason)
    }

    private func finish(reason: String) {
        guard !ended else { return }
        ended = true
        suspended = nil
        let reason = peerBye?.reason ?? reason
        let relink = relinking
        statsTimer?.cancel()
        statsTimer = nil
        watchTimer?.cancel()
        watchTimer = nil
        // A code still showing closes with the connection
        if pairing != nil, let auth = auth { DispatchQueue.main.async { auth.onCode(nil, "") } }
        cursorChannel?.close(reason: reason)
        cursorChannel = nil
        handovers.values.forEach { $0.connection.close(reason: reason) }
        handovers.removeAll()
        takeover?.close(reason: reason)
        takeover = nil
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
