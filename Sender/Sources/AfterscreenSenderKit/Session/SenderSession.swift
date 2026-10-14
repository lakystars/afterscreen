import CoreGraphics
import CryptoKit
import Foundation
import AfterscreenCore

/// Connection carrying sound; set on main, read by audio
private final class SoundRoute {
    private let lock = NSLock()
    private var current: Connection?

    var connection: Connection? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Everything the menu bar shows, refreshed at 1 Hz
public struct SenderSnapshot {
    public var state = "Idle"
    public var isStreaming = false
    public var peer: Welcome?
    public var link: LinkKind?
    public var interface: String?
    public var mtu: Int?
    public var config: StreamConfig?
    public var capacityGbps: Double?
    public var throughputBitsPerSecond = 0.0
    public var throughputHistory: [Double] = []
    public var latencyMs: Double?
    public var latencyHistory: [Double] = []
    public var jitterMs = 0.0
    public var retransmitPercent = 0.0
    public var cableScore: Int?
    public var captureFPS = 0.0
    public var sentFPS = 0.0
    public var droppedPerMinute = 0
    public var dirtyPercent = 0.0
    public var compressionRatio = 0.0
    public var encodeMs = 0.0
    /// Tiles shown lossy (BC1 or video) after the latest frame
    public var lossyTiles = 0
    public var cpuPercent = 0.0
    public var memoryBytes: UInt64 = 0
    public var gpuPercent = 0.0
    public var receiver: ReceiverStats?
    /// Video bitrate now; nil on the tile path
    /// Or after a video encoder failure: BC1 carries motion
    public var videoBitrate: Int?
    /// Video bitrate from the link probe
    public var videoStartBitrate: Int?
    /// Congestion turned the picture down for a while
    public var qualityLowered = false
    /// High-refresh experiment's outcome; nil while not asked
    public var highRefresh: HighRefresh.Verdict?
    public var qualityTest: QualityTest.Report?
    /// Chosen link did not answer; the fastest carries the stream
    public var missingLink: LinkKind?
    /// This Mac's sound goes to the receiver
    public var soundOnReceiver = false
    /// Receiver output's level; nil while it keeps its own
    public var outputLevel: OutputLevel?
    /// Built-in panel level; nil without one or lid closed
    public var macBrightness: Double?
    /// Receiver showing a pairing code, by name
    public var pairing: String?
    /// Wrong codes typed for this pairing
    public var wrongCodes = 0

    public init() {}

    /// The numbers the receiver's HUD shows
    public var wireStats: SenderStats {
        var s = SenderStats(interface: interface, mtu: mtu, capacityGbps: capacityGbps, throughputBitsPerSecond: throughputBitsPerSecond,
                    latencyMs: latencyMs, jitterMs: jitterMs, retransmitPercent: retransmitPercent, cableScore: cableScore,
                    captureFPS: captureFPS, sentFPS: sentFPS, droppedPerMinute: droppedPerMinute, dirtyPercent: dirtyPercent,
                    compressionRatio: compressionRatio, encodeMs: encodeMs, lossyTiles: lossyTiles, cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes, gpuPercent: gpuPercent)
        s.videoBitrate = videoBitrate
        return s
    }
}

/// One connection to a receiver: route, handshake, probe
/// Then virtual display, capture and encode, or a quality test
public final class SenderSession {
    public enum Purpose {
        case display
        case qualityTest
    }

    public var onUpdate: ((SenderSnapshot) -> Void)?
    public var onEnd: ((String) -> Void)?
    public private(set) var snapshot = SenderSnapshot()
    /// The receiver's user stopped the stream
    public private(set) var pausedByReceiver = false
    /// Receiver gave way to this session: connect again
    public private(set) var askedBack = false
    /// Debug: the receiver tints blocks as they arrive
    /// Rides the stats: on screen within a second
    public var flashBlocks = false

    let target: DiscoveredReceiver
    /// This Mac's identity and kept keys, for pairing
    private let senderID: String
    private let pairings: PairingStoring
    private let helloNonce = Pairing.nonce()
    /// Welcome held until the receiver is proven or paired
    private var pendingWelcome: Welcome?
    private var pendingPair: (session: SymmetricKey, key: Data, transcript: Pairing.Transcript)?
    private let purpose: Purpose
    private let link: LinkKind?
    private var route: Route?
    /// Other links' routes, tried when all chosen-link routes fail
    private var fallback: [Route] = []
    /// Cursor and audio channel; never waits behind queued frames
    /// Main connection is the fallback
    private var cursorConnection: Connection? { didSet { routeSound() } }
    /// Where sound goes now; the audio thread reads it
    private let soundRoute = SoundRoute()
    private var displaySize: DisplaySize
    private var sound: Bool
    /// Experiment: above 60 fps when the encoder keeps up
    private let highRefresh: Bool
    private var deband: Deband
    /// Last brightness sent; the receiver's panel follows this Mac's
    private var brightnessSent: Double?
    /// Receiver's own slider level; nil follows this Mac
    private var ownBrightness: Double?
    /// Largest video layer encoded at the stream's rate
    private var videoCap: PixelSize?
    /// Ignored by the quality test, which measures the panel
    private let resolution: StreamResolution
    private let role: DisplayRole
    private let fit: MirrorFit
    /// Mirror for this Mac: the display copied, per session
    private(set) var mirrorSource: MirrorSource?
    /// Mirror for the iMac: macOS mirrors into the virtual display
    private var osMirror: DisplayMirror?
    /// Disconnect reason while the receiver powers off
    private var closing: String?
    /// AudioTap, macOS 14.2 and later
    private var audioTap: AnyObject?
    /// This Mac's volume and mute, followed by the receiver
    private var output: OutputWatcher?
    private var outputSent = false
    private var testRun: QualityTestRun?
    private var connection: Connection? { didSet { routeSound() } }
    private var handoff: Handoff?
    /// This Mac ends the session: its close is no loss
    private var stopping = false
    /// Media checks in a row finding the link down
    private var inactiveChecks = 0
    /// Main queue: a lost link came back, or did not
    /// `true`: resumed over `to`; `false`: the session ends next
    public var onResume: ((_ resumed: Bool, _ from: LinkKind?, _ to: LinkKind) -> Void)?
    private var display: VirtualDisplay?
    private var capture: Capture?
    private var cursor: CursorTracker?
    private var streamer: FrameStreamer?
    /// While streaming: no App Nap timer coalescing
    /// No idle sleep under the extended display
    private var activity: NSObjectProtocol?
    private var timers: [DispatchSourceTimer] = []
    private var ended = false
    private let metrics = ProcessMetrics()
    private var latency = LatencyStats(window: 40)
    private var throughput = History(capacity: 120)
    private var latencyHistory = History(capacity: 120)
    private var lastTCP: TCPInfo?
    private var qualityNotice = QualityNotice()
    private var lastSample = Date()

    /// Development: pace writes at this Mbps; treat route as Wi-Fi
    public static var simulatedLinkMbps: Double?
    /// Development: one telemetry line per second on stderr
    public static var logStats = false

    /// `link`: link to use; nil or unreachable uses the fastest
    public init(target: DiscoveredReceiver, purpose: Purpose = .display, displaySize: DisplaySize = .standard, link: LinkKind? = nil,
                sound: Bool = false, deband: Deband = .normal, resolution: StreamResolution = .panel,
                role: DisplayRole = .extend, fit: MirrorFit = .mac, ownBrightness: Double? = nil, highRefresh: Bool = false,
                senderID: String = "", pairings: PairingStoring = MemoryPairingStore()) {
        self.target = target
        self.senderID = senderID
        self.pairings = pairings
        self.purpose = purpose
        self.displaySize = displaySize
        self.link = link
        self.sound = sound
        self.deband = deband
        self.resolution = resolution
        self.role = role
        self.fit = fit
        self.ownBrightness = ownBrightness
        self.highRefresh = highRefresh
    }

    /// Main queue: nil follows this Mac; a level sets the receiver's
    public func setReceiverBrightness(_ level: Double?) {
        ownBrightness = level
        // Levels of the two modes are different scales
        brightnessSent = nil
        if snapshot.isStreaming { followBrightness() }
    }

    /// Receiver 8-bit step smoothing; sent at handshake and on change
    public func setDeband(_ level: Deband) {
        deband = level
        connection?.send(Message(type: .deband, payload: DebandWire.encode(level)))
    }

    /// Main queue: starts or stops this Mac's sound while streaming
    public func setSound(_ on: Bool) {
        sound = on
        guard snapshot.isStreaming else { return }
        if on { return startSound() }
        stopSound()
        sendOutputLevel(playing: false)
    }

    private func startSound() {
        guard audioTap == nil, sound, snapshot.peer?.audioPlayback == true, soundRoute.connection != nil else { return }
        // Level first: no sound at the iMac's own level
        sendOutputLevel(playing: true)
        if #available(macOS 14.2, *) {
            // Looked up per packet: a handover moves the channel
            let route = soundRoute
            audioTap = AudioTap(onSamples: { rate, channels, samples in
                route.connection?.send(Message(type: .audio, payload: AudioWire.encode(sampleRate: rate, channels: channels, samples: samples)))
            }, onChange: { [weak self] in
                // A new output device or format: rebuild the tap
                self?.stopSound()
                self?.startSound()
            })
        }
        update { $0.soundOnReceiver = audioTap != nil }
        guard audioTap != nil else { return sendOutputLevel(playing: false) }
        if output == nil {
            output = OutputWatcher { [weak self] _ in
                guard let self = self else { return }
                self.sendOutputLevel(playing: self.audioTap != nil)
            }
        }
    }

    /// Cursor channel from the handshake: sound never waits behind frames
    private func routeSound() {
        soundRoute.connection = cursorConnection ?? connection
    }

    /// Receiver keeps this Mac's level across a tap rebuild
    private func stopSound() {
        if #available(macOS 14.2, *) { (audioTap as? AudioTap)?.stop() }
        audioTap = nil
        output?.stop()
        output = nil
        update { $0.soundOnReceiver = false }
    }

    /// Receiver's output takes this Mac's volume and mute
    /// nil returns its own: sound off or fixed-volume output
    /// Sent with the sound, never queued behind frames
    private func sendOutputLevel(playing: Bool) {
        let level = playing ? SystemOutput().level : nil
        // First send always goes; relinked receivers hold the last level
        guard !outputSent || level != snapshot.outputLevel else { return }
        outputSent = true
        update { $0.outputLevel = level }
        (cursorConnection ?? connection)?.send(Message(type: .volume, payload: OutputLevelWire.encode(level)))
    }

    /// Receiver's panel takes this Mac's luminance, in nits
    /// Not the slider: panels map the slider differently
    /// Change judged on the slider; dim nits steps are tiny
    /// Polled: macOS posts no public brightness change
    /// No built-in panel or lid closed: receiver keeps its own
    /// A set level goes as the receiver's slider, no nits
    private func followBrightness() {
        let panel = PanelBrightness.builtIn
        if snapshot.macBrightness != panel?.level { update { $0.macBrightness = panel?.level } }
        if let own = ownBrightness {
            guard SenderSession.brightnessChanged(own, from: brightnessSent) else { return }
            brightnessSent = own
            connection?.send(Message(type: .brightness, payload: BrightnessWire.encode(PanelLight(nits: nil, level: own))))
            return
        }
        guard let panel = panel else {
            // Resent once the panel reads again
            brightnessSent = nil
            return
        }
        guard SenderSession.brightnessChanged(panel.level, from: brightnessSent) else { return }
        brightnessSent = panel.level
        let light = PanelLight(nits: PanelBrightness.builtInPeakNits.map { panel.linear * $0 }, level: panel.level)
        connection?.send(Message(type: .brightness, payload: BrightnessWire.encode(light)))
    }

    /// Steps below 0.4% are sensor noise, not a change
    static func brightnessChanged(_ level: Double, from sent: Double?) -> Bool {
        sent.map { abs($0 - level) >= 0.004 } ?? true
    }

    /// Main queue: switches the virtual display's "looks like" size
    public func setDisplaySize(_ size: DisplaySize) {
        displaySize = size
        guard let display = display, let peer = snapshot.peer, display.setMode(points: size.points(for: peer.panelPoints)) else { return }
        // Cursor size in stream pixels changes with display size
        cursor?.resendImage()
    }

    // MARK: - Lifecycle (main queue)

    public func start() {
        update { $0.state = L10n.t("Finding a route", "경로 찾는 중") }
        RoutePlanner.routes(to: target) { [weak self] routes in
            DispatchQueue.main.async {
                guard let self = self, !self.ended else { return }
                let chosen = RoutePlanner.select(routes, prefer: self.link)
                guard !chosen.routes.isEmpty else { return self.end(L10n.t("No Thunderbolt, USB, Ethernet or Wi-Fi route to \(self.target.name)",
                                                                                  "\(self.target.name)까지 Thunderbolt, USB, 이더넷, Wi-Fi 경로가 없습니다")) }
                self.update { $0.missingLink = chosen.fellBack ? self.link : nil }
                self.fallback = RoutePlanner.fallback(routes, prefer: self.link)
                self.connect(chosen.routes)
            }
        }
    }

    private func connect(_ routes: [Route]) {
        guard let route = routes.first else {
            guard fallback.isEmpty else {
                update { $0.missingLink = link }
                let others = fallback
                fallback = []
                return connect(others)
            }
            return end(L10n.t("Could not reach \(target.name)", "\(target.name)에 연결할 수 없습니다"))
        }
        update { $0.state = L10n.t("Connecting via \(LinkLabel.name(route.kind))", "\(LinkLabel.name(route.kind))로 연결 중") }
        Connection.connect(host: route.address, port: target.port,
                           interfaceName: route.kind == .loopback ? nil : route.interface, timeout: 2) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.ended else {
                    if case let .success(c) = result { c.close(reason: "Cancelled") }
                    return
                }
                switch result {
                case let .success(c): self.connected(c, route: route)
                case .failure: self.connect(Array(routes.dropFirst()))
                }
            }
        }
    }

    private func connected(_ c: Connection, route: Route) {
        connection = c
        self.route = route
        let simulated = SenderSession.simulatedLinkMbps
        c.paceBitsPerSecond = simulated.map { $0 * 1e6 }
        c.onMessage = { [weak self] m in self?.handle(m) }
        c.onClose = { [weak self] reason in self?.connectionClosed(reason) }
        c.start(queue: .main, idleTimeout: SenderSession.idleTimeout)
        startPing()
        update {
            $0.link = simulated == nil ? route.kind : .wifi
            $0.interface = route.interface
            $0.mtu = Interfaces.mtu(route.interface)
            $0.state = L10n.t("Handshake", "연결 확인 중")
        }
        let host = ComputerName.current
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Claimed as `expectsProof` judges: by ID or by name
        // A receiver without the key shows a code, cables too
        let paired = (!target.deviceID.isEmpty && pairings.key(for: target.deviceID) != nil) || pairings.pairs.contains { $0.name == target.name }
        connection?.send(.hello, json: Hello(protocolVersion: AfterscreenProtocol.version, name: host, model: HardwareModel.identifier,
                                             osVersion: "\(os.majorVersion).\(os.minorVersion)", senderID: senderID, nonce: helloNonce,
                                             paired: paired, repair: SenderSession.disowned.contains(target.deviceID) ? true : nil))
    }

    /// `relink`: new session follows at once; receiver keeps its picture
    public func stop(reason: String = SenderSession.stoppedHere, relink: Bool = false) {
        stopping = true
        // Resuming: nothing to say bye on
        guard let c = connection, !ended, !c.isClosed else { return end(reason) }
        // A closing session already powered the iMac off
        c.send(.bye, json: Bye(reason: reason, relink: relink && closing == nil))
        c.closeAfterFlush(reason: reason)
    }

    public var isClosing: Bool { closing != nil }

    /// Main queue: a disconnect the iMac plays out
    /// Picture and sound stay live through its power-off
    /// Ends at its bye, as the screen turns black
    public func close(reason: String = SenderSession.stoppedHere) {
        guard closing == nil else { return }
        guard snapshot.isStreaming, purpose == .display, let c = connection, !c.isClosed else { return stop(reason: reason) }
        closing = reason
        c.send(.powerOff, json: Bye(reason: reason))
        // Longest power-off is 0.85 s; a silent receiver ends anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stop(reason: reason) }
    }

    /// Live link: pings and stats at least twice a second
    static let idleTimeout: TimeInterval = 4

    // MARK: - Handover (main queue)

    public enum HandoverOutcome {
        /// Frames flow on the new link
        case switched
        /// Still on the old link
        case stayed
        /// The receiver may have moved: the session relinks
        case lost
    }

    private struct Handoff {
        /// Resuming: the route found decides it
        var kind: LinkKind
        let secret: SymmetricKey
        let nonce = Pairing.nonce()
        let done: (HandoverOutcome) -> Void
        /// Old link gone: switchover on the new; all tiles again
        var resume = false
        var connection: Connection?
        var route: Route?
        var receiverNonce: Data?
        /// Both proofs checked: the new link is measured next
        var proven = false
        /// The new link's measure and the config it gives
        var gbps: Double?
        var config: StreamConfig?
        var videoCap: PixelSize?
        /// `switchover` sent: the receiver may read the new connection
        var switching = false
        /// Resume: the lost interface
        var lost: String?
        /// Resume: no new try after this uptime
        var triesUntil: TimeInterval = 0
        /// Resume: routes after the connected one, this round
        var untried: [Route] = []
        /// Resume: tells stale callbacks from the current try
        var attempt = 0
        /// Last connect error, for the log
        var lastError: String?

        /// Resume: the next try starts clean
        mutating func reset() {
            connection = nil
            route = nil
            receiverNonce = nil
            proven = false
            gbps = nil
            config = nil
            videoCap = nil
            untried = []
            attempt += 1
        }
    }

    public var isHandingOver: Bool { handoff != nil }

    /// Handshake, measure, encoder check and switch
    static let handoverTimeout: TimeInterval = 6
    /// Receiver holds 8 s; it may notice 1 s sooner
    static let resumeTimeout: TimeInterval = 7
    /// No try after this: 1.5 s to connect, then handshake
    static let resumeTries: TimeInterval = 4.5
    /// A try unproven this long after connecting: next route
    /// Once proven, probe and encoder check may take seconds
    static let resumeTryLimit: TimeInterval = 3
    static var resumeFailed: String {
        L10n.t("The link dropped and no other link took over", "링크가 끊겨 다른 링크로 잇지 못했습니다")
    }

    /// Moves the stream to `kind` within this session
    /// false: this receiver or session cannot; relink instead
    public func handover(to kind: LinkKind, done: @escaping (HandoverOutcome) -> Void) -> Bool {
        guard purpose == .display, snapshot.isStreaming, closing == nil, !ended, handoff == nil, streamer != nil,
              let welcome = snapshot.peer, let token = welcome.handoverToken else { return false }
        // 120 fps is Thunderbolt only; elsewhere a new session
        guard (snapshot.config?.frameRate ?? 0) <= HighRefresh.base || kind == .thunderbolt else { return false }
        // The key this session proved; none for an open session
        let key = welcome.auth == nil ? nil : welcome.receiverID.flatMap { pairings.key(for: $0) }
        guard welcome.auth == nil || key != nil else { return false }
        let h = Handoff(kind: kind, secret: Handover.secret(key: key, token: token), done: done)
        handoff = h
        RoutePlanner.routes(to: target) { [weak self] routes in
            DispatchQueue.main.async {
                // A resume may have replaced it meanwhile
                guard let self = self, self.handoff?.nonce == h.nonce else { return }
                self.connectHandoff(routes.filter { $0.kind == kind })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SenderSession.handoverTimeout) { [weak self] in
            guard let self = self, self.handoff?.nonce == h.nonce else { return }
            self.handoffFailed("handover timed out")
        }
        return true
    }

    /// `refused`: every route so far refused the port
    private func connectHandoff(_ routes: [Route], refused: Bool? = nil) {
        guard let h = handoff, !ended else { return }
        let nonce = h.nonce, attempt = h.attempt
        // Port closed everywhere: receiver restarted, session gone
        guard let route = routes.first else { return handoffFailed(h.lastError ?? "no route", retry: refused != true) }
        Connection.connect(host: route.address, port: target.port,
                           interfaceName: route.kind == .loopback ? nil : route.interface, timeout: 2) { [weak self] result in
            DispatchQueue.main.async {
                // A later handover's or try's result is not this one's
                guard let self = self, var h = self.handoff, h.nonce == nonce, h.attempt == attempt, h.connection == nil, !self.ended else {
                    if case let .success(c) = result { c.close(reason: "Cancelled") }
                    return
                }
                let c: Connection
                switch result {
                case let .success(connection):
                    c = connection
                case let .failure(error):
                    self.handoff?.lastError = "\(route.interface) \(route.address): \(error)"
                    var closed = false
                    if case let TransportError.system(_, code) = error { closed = code == ECONNREFUSED }
                    return self.connectHandoff(Array(routes.dropFirst()), refused: (refused ?? true) && closed)
                }
                h.connection = c
                h.route = route
                if h.resume {
                    h.kind = route.kind
                    h.untried = Array(routes.dropFirst())
                    DispatchQueue.main.asyncAfter(deadline: .now() + SenderSession.resumeTryLimit) { [weak self] in
                        guard let self = self, let h = self.handoff, h.nonce == nonce, h.attempt == attempt, !h.proven,
                              !h.untried.isEmpty || ProcessInfo.processInfo.systemUptime < h.triesUntil else { return }
                        self.handoffFailed("\(route.interface) stalled")
                    }
                }
                self.handoff = h
                c.onMessage = { [weak self, weak c] m in
                    guard let self = self, self.handoff?.connection === c else { return }
                    self.handoffMessage(m)
                }
                c.onClose = { [weak self, weak c] reason in
                    guard let self = self, self.handoff?.connection === c else { return }
                    self.handoffFailed(reason)
                }
                c.start(queue: .main)
                c.send(.handover, json: HandoverNonce(nonce: h.nonce))
            }
        }
    }

    private func handoffMessage(_ m: Message) {
        guard var h = handoff, let c = h.connection else { return }
        switch m.type {
        case .handoverChallenge:
            guard let challenge = try? JSONWire.decode(HandoverNonce.self, from: m.payload), challenge.nonce.count == 16 else {
                return handoffFailed("bad handover challenge", retry: false)
            }
            h.receiverNonce = challenge.nonce
            handoff = h
            c.send(.handoverProof, json: AuthProof(mac: Handover.proof(h.secret, role: .sender, senderNonce: h.nonce, receiverNonce: challenge.nonce)))
        case .handoverOK:
            // Proven both ways before any frame goes there
            guard let theirs = h.receiverNonce, let proof = try? JSONWire.decode(AuthProof.self, from: m.payload),
                  Pairing.matches(proof.mac, Handover.proof(h.secret, role: .receiver, senderNonce: h.nonce, receiverNonce: theirs)) else {
                return handoffFailed(L10n.t("The receiver's handover proof did not match", "수신기의 링크 전환 증명이 맞지 않습니다"), retry: false)
            }
            h.proven = true
            handoff = h
            // The old link streams on meanwhile
            probe(c)
        case .probeResult:
            guard h.proven, h.gbps == nil, let result = try? JSONWire.decode(ProbeResult.self, from: m.payload) else { return }
            h.gbps = result.gbps
            handoff = h
            chooseHandoff(gbps: result.gbps)
        case .switchover:
            guard h.switching, let route = h.route else { return }
            switched(to: c, route: route, kind: h.kind)
        case .bye:
            handoffFailed((try? JSONWire.decode(Bye.self, from: m.payload))?.reason ?? "handover refused", retry: false, told: true)
        default:
            break
        }
    }

    /// Size and rate stay; path and video follow the link
    /// A larger video layer is checked against the encoder first
    private func chooseHandoff(gbps: Double) {
        guard let h = handoff, let welcome = snapshot.peer, var current = snapshot.config else { return handoffFailed("no stream to move", retry: false) }
        // 120 fps is Thunderbolt only
        if h.kind != .thunderbolt { current.frameRate = min(current.frameRate, HighRefresh.base) }
        let first = PathPolicy.relink(current, link: h.kind, capacityGbps: gbps, welcome: welcome, largestVideo: videoCap)
        guard let layer = first.video else { return beginSwitch(first, videoCap: videoCap) }
        let boxes = PathPolicy.videoBoxes(bitrate: layer.bitrate, codec: layer.codec, fps: first.frameRate)
        // Stream's encoder busy: kept results, else its cap
        if current.video != nil {
            let largest = EncoderCapacity.knownLargest(of: boxes, codec: layer.codec, tenBit: layer.tenBit, fps: first.frameRate) ?? videoCap
            return beginSwitch(PathPolicy.relink(current, link: h.kind, capacityGbps: gbps, welcome: welcome, largestVideo: largest), videoCap: largest)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let largest = EncoderCapacity.largest(of: boxes, codec: layer.codec, tenBit: layer.tenBit, bitrate: layer.bitrate, fps: first.frameRate)
            DispatchQueue.main.async {
                guard let self = self, self.handoff?.nonce == h.nonce, self.handoff?.attempt == h.attempt else { return }
                self.beginSwitch(PathPolicy.relink(current, link: h.kind, capacityGbps: gbps, welcome: welcome, largestVideo: largest), videoCap: largest)
            }
        }
    }

    private func beginSwitch(_ config: StreamConfig, videoCap: PixelSize?) {
        guard var h = handoff, let c = h.connection else { return }
        h.config = config
        h.videoCap = videoCap
        h.switching = true
        handoff = h
        // Old link gone: the switchover goes on the new one
        if h.resume { return c.send(Message(type: .switchover)) }
        // The receiver closes the old one on reading the new
        // That close may beat the echo: not an end
        connection?.onClose = { [weak self] reason in
            guard let self = self, self.handoff?.switching != true else { return }
            self.end(reason)
        }
        streamer?.switchConnection(to: c)
    }

    /// The receiver reads the new connection: the session moves there
    private func switched(to c: Connection, route: Route, kind: LinkKind) {
        guard let h = handoff else { return }
        handoff = nil
        let old = connection
        connection = c
        self.route = route
        c.onMessage = { [weak self] m in self?.handle(m) }
        c.onClose = { [weak self] reason in self?.connectionClosed(reason) }
        c.paceBitsPerSecond = SenderSession.simulatedLinkMbps.map { $0 * 1e6 }
        c.watchIdle(SenderSession.idleTimeout)
        if h.resume, let config = h.config ?? snapshot.config {
            streamer?.resume(on: c, config: config, capacityGbps: h.gbps)
        } else {
            streamer?.finishSwitch(config: h.config, capacityGbps: h.gbps)
        }
        if let cap = h.videoCap { videoCap = cap }
        // The new link starts its own congestion record
        qualityNotice = QualityNotice()
        // Its close ends nothing now
        old?.onClose = nil
        old?.onMessage = nil
        old?.closeAfterFlush(reason: "handed over")
        lastTCP = nil
        update {
            $0.link = SenderSession.simulatedLinkMbps == nil ? kind : .wifi
            $0.interface = route.interface
            $0.mtu = Interfaces.mtu(route.interface)
            $0.config = h.config ?? $0.config
            $0.config?.linkKind = kind
            $0.missingLink = nil
            $0.capacityGbps = h.gbps
            $0.videoBitrate = h.config?.video?.bitrate
            $0.videoStartBitrate = h.config?.video?.bitrate
            $0.qualityLowered = false
            $0.state = L10n.t("Streaming", "스트리밍 중")
        }
        // Cursor and sound follow over the new route
        cursorConnection?.close(reason: "handed over")
        cursorConnection = nil
        if let token = snapshot.peer?.channelToken { openCursorChannel(token: token) }
        if SenderSession.logStats {
            let video = h.config?.video.map { "\($0.pixels.width)x\($0.pixels.height) at \($0.bitrate / 1_000_000) Mbps" } ?? "none"
            let line = String(format: "[sender] %@ to %@ via %@, %.2f Gbps measured, %@ path, video %@\n", h.resume ? "resumed" : "handed over",
                              kind.rawValue, route.interface, h.gbps ?? 0, h.config?.path.rawValue ?? "same", video)
            FileHandle.standardError.write(Data(line.utf8))
        }
        h.done(.switched)
    }

    /// `retry`: a resume goes on while time is left
    /// The round's other routes, then a new lookup
    /// `told`: the receiver's reason, shown as the end
    private func handoffFailed(_ reason: String, retry: Bool = true, told: Bool = false) {
        guard var h = handoff else { return }
        if let c = h.connection {
            c.onClose = nil
            c.onMessage = nil
            c.close(reason: reason)
        }
        if SenderSession.logStats { FileHandle.standardError.write(Data("[sender] handover to \(h.kind.rawValue) failed: \(reason)\n".utf8)) }
        let rest = h.untried
        if h.resume, retry, !h.switching, !rest.isEmpty || ProcessInfo.processInfo.systemUptime < h.triesUntil {
            h.reset()
            handoff = h
            // The round's first route connected: not a closed port
            if !rest.isEmpty { return connectHandoff(rest, refused: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.handoff?.nonce == h.nonce, self.handoff?.attempt == h.attempt else { return }
                self.seekResume(wait: 1)
            }
            return
        }
        handoff = nil
        // The lost link did not come back: session ends
        if h.resume {
            h.done(.lost)
            return end(told ? reason : SenderSession.resumeFailed)
        }
        guard h.switching else { return h.done(.stayed) }
        // Receiver may read the new one: relink, or end if cut
        h.done(.lost)
        connection?.isClosed == false ? stop(reason: reason, relink: true) : end(reason)
    }

    /// A close without a bye: maybe the cable
    private func connectionClosed(_ reason: String) {
        guard !ended else { return }
        canResume ? linkLost(reason) : end(reason)
    }

    /// Streaming, not ended here, and the receiver resumes
    private var canResume: Bool {
        purpose == .display && snapshot.isStreaming && closing == nil && !stopping && !ended && streamer != nil
            && snapshot.peer?.handoverToken != nil && handoff?.resume != true
    }

    /// The session's link is gone: resume over another
    /// Display, capture and encoder stay; the receiver holds its picture
    private func linkLost(_ reason: String) {
        guard canResume, let welcome = snapshot.peer, let token = welcome.handoverToken else { return end(reason) }
        let key = welcome.auth == nil ? nil : welcome.receiverID.flatMap { pairings.key(for: $0) }
        guard welcome.auth == nil || key != nil else { return end(reason) }
        let lost = route
        connection?.onClose = nil
        connection?.close(reason: reason)
        // Switching already, its new link proven: resume there
        if var other = handoff, other.switching, let next = other.connection {
            other.resume = true
            handoff = other
            streamer?.hold()
            return next.send(Message(type: .switchover))
        }
        // A handover not yet switching gives way, told after
        let cancelled = handoff
        if let other = cancelled {
            other.connection?.onClose = nil
            other.connection?.close(reason: reason)
        }
        streamer?.hold()
        var h = Handoff(kind: lost?.kind ?? .wifi, secret: Handover.secret(key: key, token: token), done: { [weak self] outcome in
            guard let self = self else { return }
            self.onResume?(outcome == .switched, lost?.kind, self.snapshot.link ?? .wifi)
        }, resume: true)
        h.lost = lost?.interface
        h.triesUntil = ProcessInfo.processInfo.systemUptime + SenderSession.resumeTries
        handoff = h
        cancelled?.done(.stayed)
        update { $0.state = L10n.t("Link lost; continuing over another", "링크가 끊겨 다른 링크로 잇는 중") }
        if SenderSession.logStats { FileHandle.standardError.write(Data("[sender] link lost (\(reason)), resuming\n".utf8)) }
        seekResume(wait: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + SenderSession.resumeTimeout) { [weak self] in
            guard let self = self, self.handoff?.nonce == h.nonce else { return }
            // Switching: the receiver may already read it
            guard self.handoff?.switching == true else { return self.handoffFailed("no other link took over", retry: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.handoff?.nonce == h.nonce else { return }
                self.handoffFailed("switchover unanswered", retry: false)
            }
        }
    }

    /// Live links; the lost one first if up again
    /// Resumed on a slower link, it stays until links change
    /// Later tries wait longer for mDNS answers
    private func seekResume(wait: TimeInterval) {
        guard let h = handoff, h.resume, h.connection == nil, !ended else { return }
        RoutePlanner.routes(to: target, wait: wait) { [weak self] routes in
            // Links still down would only time out
            let alive = routes.filter { Interfaces.isActive($0.interface) != false }
            let ordered = alive.filter { $0.interface == h.lost } + alive.filter { $0.interface != h.lost }
            DispatchQueue.main.async {
                guard let self = self, self.handoff?.nonce == h.nonce, self.handoff?.attempt == h.attempt else { return }
                self.connectHandoff(ordered)
            }
        }
    }

    /// Cable out: resume now, not after the idle timeout
    /// Down in a row: 1 s cables, 2 s Wi-Fi
    private func checkRoute() {
        guard let route = route, route.kind != .loopback, canResume else { return inactiveChecks = 0 }
        inactiveChecks = Interfaces.isActive(route.interface) == false ? inactiveChecks + 1 : 0
        guard inactiveChecks >= (route.kind == .wifi ? 4 : 2) else { return }
        inactiveChecks = 0
        linkLost(L10n.t("\(LinkLabel.name(route.kind)) disconnected", "\(LinkLabel.name(route.kind)) 연결이 끊겼습니다"))
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        // A closing session ends with its own reason
        let reason = closing ?? reason
        if snapshot.pairing != nil { update { $0.pairing = nil } }
        if SenderSession.logStats { FileHandle.standardError.write(Data("[sender] session ended: \(reason)\n".utf8)) }
        timers.forEach { $0.cancel() }
        timers.removeAll()
        testRun?.stop()
        testRun = nil
        capture?.stop()
        capture = nil
        streamer?.stop()
        streamer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        cursor?.stop()
        cursor = nil
        cursorConnection?.close(reason: reason)
        cursorConnection = nil
        if let c = handoff?.connection {
            c.onClose = nil
            c.close(reason: reason)
        }
        handoff = nil
        stopSound()
        // Unmirror before the virtual display goes: this Mac's mode returns
        osMirror?.stop()
        osMirror = nil
        display = nil
        connection?.close(reason: reason)
        update {
            $0.isStreaming = false
            $0.state = reason
        }
        onEnd?(reason)
    }

    // MARK: - Protocol (main queue)

    private func handle(_ m: Message) {
        switch m.type {
        case .welcome:
            guard let welcome = try? JSONWire.decode(Welcome.self, from: m.payload) else { return end(L10n.t("The receiver sent an invalid reply", "수신기가 잘못된 응답을 보냈습니다")) }
            guard PathPolicy.isPlausible(welcome) else { return end(L10n.t("The receiver reported an invalid display size", "수신기가 잘못된 화면 크기를 보냈습니다")) }
            update { $0.peer = welcome }
            guard welcome.protocolVersion == AfterscreenProtocol.version else { return }
            // A paired receiver must prove itself, never skip it
            // A look-alike may take its name, ID while it sleeps
            guard let challenge = welcome.auth else {
                guard !SenderSession.expectsProof(pairedTarget: !target.deviceID.isEmpty && pairings.key(for: target.deviceID) != nil,
                                                  pairedReceiver: welcome.receiverID.map { pairings.key(for: $0) != nil } ?? false,
                                                  pairedName: pairings.pairs.contains { $0.name == target.name }) else {
                    return stop(reason: L10n.t("No pairing proof came from \(welcome.name)", "\(welcome.name)에서 페어링 증명이 오지 않았습니다"))
                }
                return admitted(welcome)
            }
            guard let receiverID = welcome.receiverID else { return stop(reason: L10n.t("The receiver sent no identity", "수신기가 식별 정보를 보내지 않았습니다")) }
            pendingWelcome = welcome
            switch challenge.mode {
            case .paired:
                guard let key = pairings.key(for: receiverID) else {
                    return stop(reason: L10n.t("\(ComputerName.current) lost its pairing with \(welcome.name); connect again to pair", "\(ComputerName.current)에 \(welcome.name) 페어링 정보가 없습니다. 다시 연결해 페어링하세요"))
                }
                connection?.send(.auth, json: AuthProof(mac: Pairing.proof(key: key, role: .sender, transcript: transcript(welcome))))
                update { $0.state = L10n.t("Checking the pairing", "페어링 확인 중") }
            case .pair:
                update {
                    $0.pairing = welcome.name
                    $0.state = SenderSession.waitingForCode
                }
            }
        case .authOK:
            guard let welcome = pendingWelcome, let receiverID = welcome.receiverID, let key = pairings.key(for: receiverID),
                  let proof = try? JSONWire.decode(AuthProof.self, from: m.payload),
                  Pairing.matches(proof.mac, Pairing.proof(key: key, role: .receiver, transcript: transcript(welcome))) else {
                return stop(reason: L10n.t("\(target.name)'s pairing proof did not match", "\(target.name)의 페어링 증명이 맞지 않습니다"))
            }
            pendingWelcome = nil
            admitted(welcome)
        case .paired:
            guard let welcome = pendingWelcome, let receiverID = welcome.receiverID, let pair = pendingPair,
                  let proof = try? JSONWire.decode(AuthProof.self, from: m.payload),
                  Pairing.matches(proof.mac, Pairing.pairedProof(pair.session, transcript: pair.transcript)) else {
                return stop(reason: L10n.t("The receiver did not confirm the pairing", "수신기가 페어링을 확인하지 않았습니다"))
            }
            guard pairings.save(pair.key, for: receiverID, name: welcome.name) else {
                return stop(reason: L10n.t("\(ComputerName.current) could not keep the pairing", "\(ComputerName.current)에 페어링을 저장하지 못했습니다"))
            }
            SenderSession.disowned.remove(receiverID)
            pendingWelcome = nil
            pendingPair = nil
            update { $0.pairing = nil }
            admitted(welcome)
        case .pairWrong:
            guard pendingPair != nil else { return }
            pendingPair = nil
            update {
                $0.wrongCodes += 1
                $0.state = SenderSession.waitingForCode
            }
        case .probeResult:
            guard let result = try? JSONWire.decode(ProbeResult.self, from: m.payload),
                  let welcome = snapshot.peer, let link = snapshot.link else { return }
            update { $0.capacityGbps = result.gbps }
            configure(link: link, gbps: result.gbps, welcome: welcome)
        case .pong:
            if let ts = try? PingWire.decode(m.payload) {
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- ts) / 1e6
                latency.add(ms: ms)
            }
        case .stats:
            guard let stats = try? JSONWire.decode(ReceiverStats.self, from: m.payload) else { return }
            snapshot.receiver = stats
            testRun?.receiverStats(stats)
        case .keyRequest:
            streamer?.requestKeyframe()
            testRun?.requestKeyframe()
        case .bye:
            let bye = try? JSONWire.decode(Bye.self, from: m.payload)
            pausedByReceiver = bye?.pause ?? false
            // Not after a disconnect from this Mac
            askedBack = bye?.relink == true && !stopping && closing == nil
            SenderSession.disowned.formUnion(SenderSession.disownedBy(bye, receiverID: pendingWelcome?.receiverID))
            end(bye?.reason ?? "Receiver stopped")
        default:
            break
        }
    }

    public static var stoppedHere: String { L10n.t("Stopped on \(ComputerName.current)", "\(ComputerName.current)에서 연결을 끊었습니다") }

    /// The pairing card names the receiver and the error
    static var waitingForCode: String { L10n.t("Waiting for the code", "코드 입력 대기 중") }

    /// Receivers whose kept key failed its proof; main queue
    /// Key stays: a look-alike's bye cannot lift the proof
    /// The next hello asks the real receiver for a code
    static var disowned: Set<String> = []
    /// Last congestion notice, any session; main queue
    private static var lastQualityNotice: TimeInterval?
    /// Automatic's last pick per receiver, this run; main queue
    private static var autoPicks: [String: StreamResolution] = [:]

    /// IDs a bye marks for pairing anew; deletes nothing
    static func disownedBy(_ bye: Bye?, receiverID: String?) -> Set<String> {
        guard bye?.repair == true, let id = receiverID else { return [] }
        return [id]
    }

    /// Known by key or name: it must answer a challenge
    static func expectsProof(pairedTarget: Bool, pairedReceiver: Bool, pairedName: Bool) -> Bool {
        pairedTarget || pairedReceiver || pairedName
    }

    /// Main queue: the receiver's code, as the user typed it
    /// A wrong code keeps the same code up for retry
    public func submitPairingCode(_ code: String) {
        guard let welcome = pendingWelcome, let challenge = welcome.auth, challenge.mode == .pair, let receiverKey = challenge.publicKey,
              pendingPair == nil else { return }
        let own = Pairing.newKey()
        var t = transcript(welcome)
        t.senderKey = own.publicKey.rawRepresentation
        t.receiverKey = receiverKey
        guard let session = try? Pairing.sessionKey(own, peer: receiverKey, transcript: t) else {
            return stop(reason: L10n.t("The receiver's pairing key is invalid", "수신기의 페어링 키가 올바르지 않습니다"))
        }
        pendingPair = (session, Pairing.pairingKey(session, code: code, transcript: t), t)
        connection?.send(.pair, json: PairConfirm(publicKey: own.publicKey.rawRepresentation, mac: Pairing.confirm(session, code: code, transcript: t)))
        update { $0.state = L10n.t("Pairing", "페어링 중") }
    }

    private func transcript(_ welcome: Welcome) -> Pairing.Transcript {
        Pairing.Transcript(senderID: senderID, receiverID: welcome.receiverID ?? "", senderNonce: helloNonce, receiverNonce: welcome.auth?.nonce ?? Data())
    }

    /// Receiver accepted this Mac: measure the link, then stream
    private func admitted(_ welcome: Welcome) {
        if SenderSession.logStats {
            let how = welcome.auth.map { $0.mode == .paired ? "proved both ways" : "paired with a code" } ?? "open, no pairing"
            FileHandle.standardError.write(Data("[sender] admitted by \(welcome.name): \(how)\n".utf8))
        }
        setDeband(deband)
        if purpose == .display { openCursorChannel(token: welcome.channelToken) }
        update { $0.state = L10n.t("Measuring the link", "링크 속도 측정 중") }
        if let c = connection { probe(c) }
    }

    /// 60 fps unless the experiment is on, over Thunderbolt
    /// fast enough for lossless tiles at 120
    /// and the encoder takes under half a 120 fps frame
    /// Timed off main at the panel's size
    private func chooseFrameRate(link: LinkKind, gbps: Double, welcome: Welcome) {
        let hz = welcome.frameRate, size = PathPolicy.aligned(welcome.panelPixels)
        let fits = gbps >= PathPolicy.tileCapacityGbps(size, fps: HighRefresh.ceiling)
        let decide = { [weak self] (ms: Double?) in
            guard let self = self, !self.ended else { return }
            let verdict = HighRefresh.verdict(enabled: self.highRefresh, link: link, receiverHz: hz, gbps: gbps, tilesFit: fits, encodeMs: ms)
            self.update { $0.highRefresh = verdict }
            if SenderSession.logStats, let v = verdict {
                FileHandle.standardError.write(Data("[sender] high refresh: \(v), receiver \(Int(hz)) Hz\n".utf8))
            }
            self.configure(link: link, gbps: gbps, welcome: welcome, maxRate: HighRefresh.maxFrameRate(verdict))
        }
        guard HighRefresh.worthTiming(enabled: highRefresh, link: link, receiverHz: hz, tilesFit: fits) else { return decide(nil) }
        update { $0.state = L10n.t("Timing the encoder", "인코더 속도 확인 중") }
        DispatchQueue.global(qos: .userInitiated).async {
            let ms = TileCapacity.fullMotionMs(size, limitMs: HighRefresh.budgetMs)
            DispatchQueue.main.async { decide(ms) }
        }
    }

    /// Picks the path and size, then starts the picture
    /// Waits up to 2 s for a changing main display
    /// For example, a virtual display that was main just left
    /// `maxRate`: nil until the high-refresh experiment has decided
    private func configure(link: LinkKind, gbps: Double, welcome: Welcome, attempt: Int = 0, maxRate: Double? = nil) {
        guard !ended else { return }
        guard let maxRate = maxRate else { return chooseFrameRate(link: link, gbps: gbps, welcome: welcome) }
        if purpose == .display, role == .mirror, fit == .mac {
            guard let source = MirrorSource.main else {
                guard attempt < 8 else { return end(L10n.t("No display to mirror", "복제할 디스플레이가 없습니다")) }
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.configure(link: link, gbps: gbps, welcome: welcome, attempt: attempt + 1, maxRate: maxRate)
                }
            }
            mirrorSource = source
        }
        let test = purpose == .qualityTest
        let choose = { (resolution: StreamResolution, source: PixelSize?, largest: PixelSize?) in
            PathPolicy.choose(link: link, capacityGbps: gbps, welcome: welcome, resolution: resolution, source: source, largestVideo: largest,
                              maxFrameRate: maxRate)
        }
        // Automatic resolved per receiver; near the line it holds
        let key = welcome.receiverID ?? target.name, screen = PathPolicy.aligned(welcome.panelPixels)
        let pick = { (source: PixelSize?) in
            PathPolicy.resolve(self.resolution, panel: screen, source: source, capacityGbps: gbps, previous: SenderSession.autoPicks[key])
        }
        // Test stages fill the panel
        // Typical use: the size a session would pick
        let source = mirrorSource?.pixels, wanted = test ? .panel : pick(source)
        if !test, resolution == .auto { SenderSession.autoPicks[key] = wanted }
        let usual = role == .mirror && fit == .mac ? MirrorSource.main?.pixels : nil
        let usualPick = pick(usual)
        let typical = { (largest: PixelSize?) in test ? choose(usualPick, usual, largest) : nil }
        guard let first = choose(wanted, source, nil) else {
            return end(L10n.t("Afterscreen supports Thunderbolt, USB, Ethernet and Wi-Fi links",
                              "Afterscreen는 Thunderbolt, USB, 이더넷, Wi-Fi 링크만 지원합니다"))
        }
        guard let layer = first.video else { return start(first, typical: typical(nil), welcome: welcome) }
        // Encoder speed varies by Mac: measured off main, per size
        let boxes = PathPolicy.videoBoxes(bitrate: layer.bitrate, codec: layer.codec, fps: first.frameRate)
        update { $0.state = L10n.t("Checking the video encoder", "영상 인코더 확인 중") }
        let asked = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let largest = EncoderCapacity.largest(of: boxes, codec: layer.codec, tenBit: layer.tenBit, bitrate: layer.bitrate, fps: first.frameRate)
            DispatchQueue.main.async {
                guard let self = self, !self.ended else { return }
                self.videoCap = largest
                if SenderSession.logStats, let l = largest {
                    let ms = Int((ProcessInfo.processInfo.systemUptime - asked) * 1000)
                    FileHandle.standardError.write(Data("[sender] encoder keeps up at \(l.width)x\(l.height), \(Int(first.frameRate)) fps, checked in \(ms) ms\n".utf8))
                }
                self.start(choose(wanted, source, largest) ?? first, typical: typical(largest), welcome: welcome)
            }
        }
    }

    private func start(_ config: StreamConfig, typical: StreamConfig?, welcome: Welcome) {
        if purpose == .qualityTest { return startQualityTest(config, typical: typical) }
        beginStreaming(config, welcome: welcome)
    }

    /// macOS takes a moment to accept a new virtual display
    /// Retries for up to 3 s; capture starts meanwhile
    private func mirror(into display: VirtualDisplay, attempt: Int = 1) {
        guard !ended, osMirror == nil else { return }
        if let source = DisplayMirror.source(excluding: display.displayID), let mirror = DisplayMirror(source: source, into: display.displayID) {
            osMirror = mirror
            if SenderSession.logStats { FileHandle.standardError.write(Data("[sender] mirroring display \(source), try \(attempt)\n".utf8)) }
            return
        }
        guard attempt < 15 else {
            if SenderSession.logStats {
                FileHandle.standardError.write(Data("[sender] mirroring refused: \(DisplayMirror.lastError ?? "no source display")\n".utf8))
            }
            return stop(reason: L10n.t("macOS did not mirror \(ComputerName.current)'s display", "macOS가 \(ComputerName.current) 디스플레이를 미러링하지 않았습니다"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak display] in
            guard let display = display else { return }
            self?.mirror(into: display, attempt: attempt + 1)
        }
    }

    /// macOS may restore an earlier mirror set for this display
    /// Checked for 2 s after the display appears
    private func keepExtended(_ display: VirtualDisplay, attempt: Int = 1) {
        guard !ended else { return }
        if DisplayMirror.release(display.displayID), SenderSession.logStats {
            FileHandle.standardError.write(Data("[sender] undid a restored mirror set, check \(attempt)\n".utf8))
        }
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak display] in
            guard let display = display else { return }
            self?.keepExtended(display, attempt: attempt + 1)
        }
    }

    /// Same route as the session
    /// On failure, the cursor stays on the main connection
    private func openCursorChannel(token: UInt32) {
        guard let route = route, token != 0 else { return }
        Connection.connect(host: route.address, port: target.port,
                           interfaceName: route.kind == .loopback ? nil : route.interface, timeout: 2) { [weak self] result in
            DispatchQueue.main.async {
                guard case let .success(c) = result else { return }
                guard let self = self, !self.ended else { return c.close(reason: "Cancelled") }
                c.onClose = { [weak self, weak c] _ in
                    if self?.cursorConnection === c { self?.cursorConnection = nil }
                }
                c.start(queue: .main)
                c.send(Message(type: .cursorChannel, payload: ChannelWire.encode(token)))
                self.cursorConnection = c
            }
        }
    }

    /// 0.3 s of 1 MiB messages on `c`; answered there
    private func probe(_ c: Connection) {
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = Data(count: 1 << 20)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while ProcessInfo.processInfo.systemUptime < deadline && !c.isClosed {
                if c.queuedMessages < 8 {
                    c.send(Message(type: .probe, payload: chunk))
                } else {
                    usleep(200)
                }
            }
            c.send(Message(type: .probe, flags: ProbeFlags.end))
        }
    }

    private func beginStreaming(_ config: StreamConfig, welcome: Welcome) {
        update {
            $0.config = config
            // Before the first sample; nil later means BC1 fallback
            $0.videoBitrate = config.video?.bitrate
            $0.state = L10n.t("Starting the display", "디스플레이 준비 중")
        }
        // Mirror captures the main display; extend adds a display
        if mirrorSource == nil {
            do {
                let modes = PathPolicy.displayModes(welcome: welcome, stream: config.streamPixels, size: displaySize)
                display = try VirtualDisplay(name: "Afterscreen — \(welcome.name)", streamPixels: config.streamPixels, hiDPI: welcome.isRetina,
                                             modes: modes.all, initial: modes.initial, millimeters: PathPolicy.millimeters(welcome),
                                             refresh: config.frameRate)
            } catch {
                return stop(reason: "\(error)")
            }
        }
        // After the display: a refused one opens no window there
        connection?.send(.config, json: config)
        if purpose == .display, let display = display {
            role == .mirror ? mirror(into: display) : keepExtended(display)
        }
        guard let displayID = mirrorSource?.displayID ?? display?.displayID, let connection = connection else { return }
        let streamer: FrameStreamer
        do {
            streamer = try FrameStreamer(config: config, capacityGbps: snapshot.capacityGbps, connection: connection)
        } catch {
            return stop(reason: "\(error)")
        }
        self.streamer = streamer
        if SenderSession.logStats {
            let g = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
            FileHandle.standardError.write(Data(String(format: "[sender] %@ path over %@, %.2f Gbps measured, BC7 motion up to %d of %d tiles, %@ %dx%d\n",
                                                       config.path.rawValue, config.linkKind.rawValue, snapshot.capacityGbps ?? 0,
                                                       PathPolicy.bc7MotionTiles(capacityGbps: snapshot.capacityGbps, tileBytes: g.tileBytes, fps: config.frameRate),
                                                       g.tileCount, role == .mirror ? "mirror-\(fit.rawValue)" : role.rawValue,
                                                       config.streamPixels.width, config.streamPixels.height).utf8))
        }

        let crop = mirrorSource?.region(for: config.streamPixels)
        let cursor = CursorTracker(displayID: displayID, crop: crop)
        cursor.onPosition = { [weak self] x, y, visible in
            guard let self = self else { return }
            (self.cursorConnection ?? self.connection)?.send(Message(type: .cursorPos, payload: CursorWire.pos(x: x, y: y, visible: visible)))
        }
        cursor.onImage = { [weak self] image in
            // Points → stream pixels; receiver needs no display size
            let k = Double(config.streamPixels.width) / max(1, Double(crop?.width ?? CGDisplayBounds(displayID).width))
            func px(_ v: Int) -> Int { Int((Double(v) * k).rounded()) }
            guard let self = self else { return }
            (self.cursorConnection ?? self.connection)?.send(Message(type: .cursorImage, payload: CursorWire.image(
                width: px(image.width), height: px(image.height), hotX: px(image.hotX), hotY: px(image.hotY), png: image.png)))
        }
        cursor.start()
        self.cursor = cursor

        let capture = Capture(displayID: displayID, size: config.streamPixels, crop: crop)
        capture.onFrame = { [weak streamer] frame in streamer?.offer(frame) }
        capture.onStop = { [weak self] reason in
            DispatchQueue.main.async {
                // Display off under a power-off: the receiver's bye ends it
                guard let self = self, self.closing == nil else { return }
                // Failed here, not the link: the receiver need not wait
                self.stop(reason: L10n.t("Screen capture stopped: \(reason)", "화면 캡처가 멈췄습니다: \(reason)"))
            }
        }
        self.capture = capture
        capture.start { [weak self] error in
            DispatchQueue.main.async {
                // App drops ended sessions; nil self means ended too
                guard let self = self, !self.ended else { return capture.stop() }
                if let error = error {
                    return self.stop(reason: L10n.t("Screen capture failed (\(error.localizedDescription)). Check Screen Recording permission.",
                                                    "화면 캡처에 실패했습니다(\(error.localizedDescription)). 화면 기록 권한을 확인하세요."))
                }
                self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                      reason: "Streaming a display")
                self.update {
                    $0.isStreaming = true
                    $0.state = L10n.t("Streaming", "스트리밍 중")
                }
                self.startSound()
                self.sendOutputLevel(playing: self.audioTap != nil)
                self.startTimers()
            }
        }
    }

    private func startQualityTest(_ config: StreamConfig, typical: StreamConfig?) {
        let stages = QualityTest.stages(panel: config.streamPixels).map { PathPolicy.stage(config, size: $0, largestVideo: videoCap) }
        let usual = typical.map { PathPolicy.stage($0, size: $0.streamPixels, largestVideo: videoCap) }
        let path = config.video.map { v in
            L10n.t("Tiles + \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10-bit" : "") for motion",
                   "타일 + 움직임은 \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10비트" : "")")
        } ?? L10n.t("Tiles", "타일")
        let report = QualityTest.Report(receiver: snapshot.peer?.marketingName ?? target.name, link: snapshot.link, path: path,
                                        frameRate: config.frameRate)
        guard let connection = connection,
              let run = QualityTestRun(connection: connection, configs: stages, typical: usual, capacityGbps: snapshot.capacityGbps, report: report) else {
            return end(L10n.t("Quality test unavailable: Metal or the test pattern failed",
                              "품질 테스트를 할 수 없습니다: Metal 또는 테스트 화면 생성 실패"))
        }
        run.onReport = { [weak self] r in
            self?.update {
                $0.qualityTest = r
                $0.state = r.running.map { r.runningTypical ? L10n.t("Testing typical use", "실사용 측정 중")
                                                             : L10n.t("Testing \(QualityTest.label($0))", "\(QualityTest.label($0)) 측정 중") }
                    ?? L10n.t("Test finished", "테스트 완료")
            }
        }
        run.onFinish = { [weak self] in
            guard let self = self else { return }
            let describe = { (s: QualityTest.Stage) in
                String(format: "%@ %d×%d %.0f fps %.2f Gb/s", QualityTest.label(s.size), s.size.width, s.size.height, s.fps, s.gbps)
                    + (s.motion.map { $0 == s.size ? "" : " (motion \($0.width)×\($0.height))" } ?? "")
                    + (s.videoBitrate.map { " video \($0 / 1_000_000) Mbps" } ?? "")
            }
            let report = self.snapshot.qualityTest
            let stages = (report?.stages ?? []).map(describe) + (report?.typical.map { ["typical use " + describe($0)] } ?? [])
            let link = String(format: "%@ via %@, %.2f Gb/s, %@", self.snapshot.link?.rawValue ?? "?", self.snapshot.interface ?? "?",
                              self.snapshot.capacityGbps ?? 0, path)
            FileHandle.standardError.write(Data("[sender] quality test (\(link)): \(stages.joined(separator: ", "))\n".utf8))
            self.stop(reason: L10n.t("Quality test finished", "품질 테스트를 마쳤습니다"))
        }
        update { $0.config = config }
        testRun = run
        // Background menu bar app: prevents 60 Hz pattern timer coalescing
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Quality test")
        run.start()
    }

    // MARK: - Telemetry (main queue)

    /// Keeps the receiver's idle watchdog fed from the handshake on
    private func startPing() {
        timers.append(DispatchSource.repeating(on: .main, every: 0.5) { [weak self] in
            self?.connection?.send(Message(type: .ping, payload: PingWire.encode(DispatchTime.now().uptimeNanoseconds)))
            self?.checkRoute()
        })
    }

    private func startTimers() {
        timers.append(DispatchSource.repeating(on: .main, every: 1, after: 1) { [weak self] in self?.sampleTelemetry() })
        // Brightness keys animate; 5 Hz keeps the iMac close behind
        timers.append(DispatchSource.repeating(on: .main, every: 0.2) { [weak self] in self?.followBrightness() })
        lastSample = Date()
    }

    private func sampleTelemetry() {
        let now = Date()
        let seconds = max(0.001, now.timeIntervalSince(lastSample))
        lastSample = now
        let c = streamer?.takeCounters() ?? FrameCounters()
        let bitsPerSecond = Double(c.bytes) * 8 / seconds
        throughput.push(bitsPerSecond)
        var retransmit = snapshot.retransmitPercent
        let tcpNow = connection?.tcpInfo()
        let link = LinkMetrics.latencyAndJitter(tcp: tcpNow, ping: latency)
        if let ms = link.latencyMs { latencyHistory.push(ms) }
        if let tcp = tcpNow {
            if let prev = lastTCP, tcp.sentPackets > prev.sentPackets {
                retransmit = Double(tcp.retransmittedPackets &- prev.retransmittedPackets) / Double(tcp.sentPackets - prev.sentPackets) * 100
            }
            lastTCP = tcp
        }
        let m = metrics.sample()
        let rates = streamer?.videoBitrates
        let notice = rates.map { qualityNotice.update(bitrate: $0.now, start: $0.start, now: ProcessInfo.processInfo.systemUptime,
                                                     lastShown: &SenderSession.lastQualityNotice) } ?? false
        let required = snapshot.config.map { c in c.video.map { 1.5 * Double($0.bitrate) / 1e9 } ?? PathPolicy.tileCapacityGbps(c.streamPixels, fps: c.frameRate) } ?? 0
        update {
            $0.throughputBitsPerSecond = bitsPerSecond
            $0.throughputHistory = throughput.values
            $0.latencyMs = link.latencyMs
            $0.latencyHistory = latencyHistory.values
            $0.jitterMs = link.jitterMs
            $0.retransmitPercent = retransmit
            $0.cableScore = CableScore.score(retransmitPercent: retransmit, jitterMs: link.jitterMs,
                                             capacityGbps: $0.capacityGbps, requiredGbps: required)
            $0.captureFPS = capture?.captured.ratePerSecond() ?? 0
            $0.sentFPS = streamer?.sent.ratePerSecond() ?? 0
            $0.droppedPerMinute = Int((streamer?.drops.ratePerSecond() ?? 0) * 60)
            $0.dirtyPercent = c.totalTiles > 0 ? Double(c.dirtyTiles) / Double(c.totalTiles) * 100 : 0
            $0.compressionRatio = c.tileWireBytes > 0 && c.rawTileBytes > 0 ? Double(c.rawTileBytes) / Double(c.tileWireBytes) : 0
            // 0: no new frame this second
            $0.encodeMs = c.encodedFrames > 0 ? c.encodeMs / Double(c.encodedFrames) : 0
            $0.lossyTiles = c.lossyTiles
            $0.cpuPercent = m.cpuPercent
            $0.memoryBytes = m.memoryBytes
            $0.gpuPercent = streamer?.gpuMeter.percentSinceLastRead() ?? 0
            $0.videoBitrate = rates?.now
            $0.videoStartBitrate = rates?.start
            $0.qualityLowered = qualityNotice.lowered
        }
        var stats = snapshot.wireStats
        stats.congestionNotice = notice ? true : nil
        stats.flashBlocks = flashBlocks ? true : nil
        connection?.send(.senderStats, json: stats)
        if SenderSession.logStats { logLine() }
    }

    private func logLine() {
        let s = snapshot, r = s.receiver
        let line = String(format: "[sender] fps %.0f/%.0f/%.0f  %.3f Gb/s  encode %.1f ms  cpu %.1f%%  receiver cpu %.1f%% gpu %.0f%% late %d  lossy %d tiles  sound %@\n",
                          s.captureFPS, s.sentFPS, r?.displayedFPS ?? 0, s.throughputBitsPerSecond / 1e9, s.encodeMs, s.cpuPercent,
                          r?.cpuPercent ?? 0, r?.gpuPercent ?? 0, r?.lateFrames ?? 0, s.lossyTiles,
                          s.soundOnReceiver ? (r?.audioBufferMs.map { String(format: "%.0f ms, %d gaps", $0, r?.audioUnderruns ?? 0) } ?? "no data") : "off")
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func update(_ change: (inout SenderSnapshot) -> Void) {
        change(&snapshot)
        onUpdate?(snapshot)
    }
}
