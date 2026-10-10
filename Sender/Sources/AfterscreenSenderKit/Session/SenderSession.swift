import CoreGraphics
import Foundation
import AfterscreenCore

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
    public var qualityTest: QualityTest.Report?
    /// Chosen link did not answer; the fastest carries the stream
    public var missingLink: LinkKind?
    /// This Mac's sound goes to the receiver
    public var soundOnReceiver = false
    /// Receiver output's level; nil while it keeps its own
    public var outputLevel: OutputLevel?

    public init() {}

    /// The numbers the receiver's HUD shows
    public var wireStats: SenderStats {
        SenderStats(interface: interface, mtu: mtu, capacityGbps: capacityGbps, throughputBitsPerSecond: throughputBitsPerSecond,
                    latencyMs: latencyMs, jitterMs: jitterMs, retransmitPercent: retransmitPercent, cableScore: cableScore,
                    captureFPS: captureFPS, sentFPS: sentFPS, droppedPerMinute: droppedPerMinute, dirtyPercent: dirtyPercent,
                    compressionRatio: compressionRatio, encodeMs: encodeMs, lossyTiles: lossyTiles, cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes, gpuPercent: gpuPercent)
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

    let target: DiscoveredReceiver
    private let purpose: Purpose
    private let link: LinkKind?
    private var route: Route?
    /// Other links' routes, tried when all chosen-link routes fail
    private var fallback: [Route] = []
    /// Cursor and audio channel; never waits behind queued frames
    /// Main connection is the fallback
    private var cursorConnection: Connection?
    private var displaySize: DisplaySize
    private var sound: Bool
    private var deband: Deband
    /// Panel brightness, sent once the stream shows (display awake)
    /// nil leaves the panel as is
    private var brightness: Double?
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
    private var connection: Connection?
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
    private var lastSample = Date()

    /// Development: pace writes at this Mbps; treat route as Wi-Fi
    public static var simulatedLinkMbps: Double?
    /// Development: one telemetry line per second on stderr
    public static var logStats = false

    /// `link`: link to use; nil or unreachable uses the fastest
    public init(target: DiscoveredReceiver, purpose: Purpose = .display, displaySize: DisplaySize = .standard, link: LinkKind? = nil,
                sound: Bool = false, deband: Deband = .normal, brightness: Double? = nil, resolution: StreamResolution = .panel,
                role: DisplayRole = .extend, fit: MirrorFit = .mac) {
        self.target = target
        self.purpose = purpose
        self.displaySize = displaySize
        self.link = link
        self.sound = sound
        self.deband = deband
        self.brightness = brightness
        self.resolution = resolution
        self.role = role
        self.fit = fit
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
        guard audioTap == nil, sound, snapshot.peer?.audioPlayback == true else { return }
        // Cursor channel from the handshake: sound never waits behind frames
        guard let channel = cursorConnection ?? connection else { return }
        // Level first: no sound at the iMac's own level
        sendOutputLevel(playing: true)
        if #available(macOS 14.2, *) {
            audioTap = AudioTap(onSamples: { rate, channels, samples in
                channel.send(Message(type: .audio, payload: AudioWire.encode(sampleRate: rate, channels: channels, samples: samples)))
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

    /// Receiver panel brightness, 0…1
    public func setBrightness(_ level: Double) {
        brightness = level
        connection?.send(Message(type: .brightness, payload: LevelWire.encode(level)))
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
        c.onClose = { [weak self] reason in self?.end(reason) }
        c.start(queue: .main, idleTimeout: SenderSession.idleTimeout)
        startPing()
        update {
            $0.link = simulated == nil ? route.kind : .wifi
            $0.interface = route.interface
            $0.mtu = Interfaces.mtu(route.interface)
            $0.state = L10n.t("Handshake", "연결 확인 중")
        }
        let host = Host.current().localizedName ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        connection?.send(.hello, json: Hello(protocolVersion: AfterscreenProtocol.version, name: host, model: HardwareModel.identifier,
                           osVersion: "\(os.majorVersion).\(os.minorVersion)"))
    }

    /// `relink`: new session follows at once; receiver keeps its picture
    public func stop(reason: String = L10n.t("Stopped on this Mac", "이 Mac에서 연결을 끊었습니다"), relink: Bool = false) {
        guard let c = connection, !ended else { return end(reason) }
        // A closing session already powered the iMac off
        c.send(.bye, json: Bye(reason: reason, relink: relink && closing == nil))
        c.closeAfterFlush(reason: reason)
    }

    public var isClosing: Bool { closing != nil }

    /// Main queue: a disconnect the iMac plays out
    /// Picture and sound stay live through its power-off
    /// Ends at its bye, as the screen turns black
    public func close(reason: String = L10n.t("Stopped on this Mac", "이 Mac에서 연결을 끊었습니다")) {
        guard closing == nil else { return }
        guard snapshot.isStreaming, purpose == .display, let c = connection else { return stop(reason: reason) }
        closing = reason
        c.send(.powerOff, json: Bye(reason: reason))
        // Longest power-off is 0.85 s; a silent receiver ends anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stop(reason: reason) }
    }

    /// Live link: pings and stats at least twice a second
    static let idleTimeout: TimeInterval = 4

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        // A closing session ends with its own reason
        let reason = closing ?? reason
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
            setDeband(deband)
            if purpose == .display { openCursorChannel(token: welcome.channelToken) }
            update { $0.state = L10n.t("Measuring the link", "링크 속도 측정 중") }
            probe()
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
            end(bye?.reason ?? "Receiver stopped")
        default:
            break
        }
    }

    /// Picks the path and size, then starts the picture
    /// Mirror waits up to 2 s for a main display change
    /// For example, a virtual display that was main just left
    private func configure(link: LinkKind, gbps: Double, welcome: Welcome, attempt: Int = 0) {
        guard !ended else { return }
        if purpose == .display, role == .mirror, fit == .mac {
            guard let source = MirrorSource.main else {
                guard attempt < 8 else { return end(L10n.t("No display to mirror", "복제할 디스플레이가 없습니다")) }
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.configure(link: link, gbps: gbps, welcome: welcome, attempt: attempt + 1)
                }
            }
            mirrorSource = source
        }
        guard let config = PathPolicy.choose(link: link, capacityGbps: gbps, welcome: welcome,
                                             resolution: purpose == .qualityTest ? .panel : resolution, source: mirrorSource?.pixels) else {
            return end(L10n.t("Afterscreen supports Thunderbolt, USB, Ethernet and Wi-Fi links",
                              "Afterscreen는 Thunderbolt, USB, 이더넷, Wi-Fi 링크만 지원합니다"))
        }
        if purpose == .qualityTest { return startQualityTest(config) }
        connection?.send(.config, json: config)
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
            return end(L10n.t("macOS did not mirror this Mac's display", "macOS가 이 Mac의 디스플레이를 미러링하지 않았습니다"))
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

    private func probe() {
        guard let c = connection else { return }
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
            $0.state = L10n.t("Starting the display", "디스플레이 준비 중")
        }
        // Mirror captures the main display; extend adds a display
        if mirrorSource == nil {
            do {
                let modes = PathPolicy.displayModes(welcome: welcome, stream: config.streamPixels, size: displaySize)
                display = try VirtualDisplay(name: "Afterscreen — \(welcome.name)", streamPixels: config.streamPixels, hiDPI: welcome.isRetina,
                                             modes: modes.all, initial: modes.initial)
            } catch {
                return end("\(error)")
            }
        }
        if purpose == .display, let display = display {
            role == .mirror ? mirror(into: display) : keepExtended(display)
        }
        guard let displayID = mirrorSource?.displayID ?? display?.displayID, let connection = connection else { return }
        let streamer: FrameStreamer
        do {
            streamer = try FrameStreamer(config: config, capacityGbps: snapshot.capacityGbps, connection: connection)
        } catch {
            return end("\(error)")
        }
        self.streamer = streamer
        if SenderSession.logStats {
            let g = TileGeometry(width: config.streamPixels.width, height: config.streamPixels.height)
            FileHandle.standardError.write(Data(String(format: "[sender] %@ path over %@, %.2f Gbps measured, BC7 motion up to %d of %d tiles, %@ %dx%d\n",
                                                       config.path.rawValue, config.linkKind.rawValue, snapshot.capacityGbps ?? 0,
                                                       PathPolicy.bc7MotionTiles(capacityGbps: snapshot.capacityGbps, tileBytes: g.tileBytes),
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
        capture.onStop = { [weak self] reason in DispatchQueue.main.async { self?.end(L10n.t("Screen capture stopped: \(reason)", "화면 캡처가 멈췄습니다: \(reason)")) } }
        self.capture = capture
        capture.start { [weak self] error in
            DispatchQueue.main.async {
                // App drops ended sessions; nil self means ended too
                guard let self = self, !self.ended else { return capture.stop() }
                if let error = error {
                    return self.end(L10n.t("Screen capture failed (\(error.localizedDescription)). Check Screen Recording permission.",
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
                if let level = self.brightness { self.setBrightness(level) }
                self.startTimers()
            }
        }
    }

    private func startQualityTest(_ config: StreamConfig) {
        let stages = QualityTest.stages(panel: config.streamPixels).map { PathPolicy.stage(config, size: $0) }
        let path = config.video.map { v in
            L10n.t("Tiles + \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10-bit" : "") for motion",
                   "타일 + 움직임은 \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10비트" : "")")
        } ?? L10n.t("Tiles", "타일")
        let report = QualityTest.Report(receiver: snapshot.peer?.marketingName ?? target.name, link: snapshot.link, path: path)
        guard let connection = connection,
              let run = QualityTestRun(connection: connection, configs: stages, capacityGbps: snapshot.capacityGbps, report: report) else {
            return end(L10n.t("Quality test unavailable: Metal or the test pattern failed",
                              "품질 테스트를 할 수 없습니다: Metal 또는 테스트 화면 생성 실패"))
        }
        run.onReport = { [weak self] r in
            self?.update {
                $0.qualityTest = r
                $0.state = r.running.map { L10n.t("Testing \(QualityTest.label($0))", "\(QualityTest.label($0)) 측정 중") }
                    ?? L10n.t("Test finished", "테스트 완료")
            }
        }
        run.onFinish = { [weak self] in
            guard let self = self else { return }
            let stages = (self.snapshot.qualityTest?.stages ?? []).map {
                String(format: "%@ %d×%d %.0f fps %.2f Gb/s", QualityTest.label($0.size), $0.size.width, $0.size.height, $0.fps, $0.gbps)
            }
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
        })
    }

    private func startTimers() {
        timers.append(DispatchSource.repeating(on: .main, every: 1, after: 1) { [weak self] in self?.sampleTelemetry() })
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
        let required = snapshot.config?.video.map { 1.5 * Double($0.bitrate) / 1e9 } ?? PathPolicy.tileCapacityGbps
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
            $0.compressionRatio = c.bytes > 0 && c.rawTileBytes > 0 ? Double(c.rawTileBytes) / Double(c.bytes) : 0
            $0.encodeMs = c.encodeMs
            $0.lossyTiles = c.lossyTiles
            $0.cpuPercent = m.cpuPercent
            $0.memoryBytes = m.memoryBytes
            $0.gpuPercent = streamer?.gpuMeter.percentSinceLastRead() ?? 0
        }
        connection?.send(.senderStats, json: snapshot.wireStats)
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
