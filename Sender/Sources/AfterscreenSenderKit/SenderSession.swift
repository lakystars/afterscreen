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
    public var cpuPercent = 0.0
    public var memoryBytes: UInt64 = 0
    public var gpuPercent = 0.0
    public var receiver: ReceiverStats?
    public var qualityTest: QualityTest.Report?

    public init() {}
}

/// One connection to a receiver: route, handshake, probe, then a virtual display with capture and encode,
/// or a quality test
public final class SenderSession {
    public enum Purpose {
        case display
        case qualityTest
    }

    public var onUpdate: ((SenderSnapshot) -> Void)?
    public var onEnd: ((String) -> Void)?
    public private(set) var snapshot = SenderSnapshot()

    private let target: DiscoveredReceiver
    private let purpose: Purpose
    private var displaySize: DisplaySize
    private var testRun: QualityTestRun?
    private var connection: Connection?
    private var display: VirtualDisplay?
    private var capture: Capture?
    private var cursor: CursorTracker?
    private var streamer: FrameStreamer?
    /// While streaming: no App Nap timer coalescing, and no idle sleep under the extended display
    private var activity: NSObjectProtocol?
    private var timers: [DispatchSourceTimer] = []
    private var ended = false
    private let metrics = ProcessMetrics()
    private var latency = LatencyStats(window: 40)
    private var throughput = History(capacity: 120)
    private var latencyHistory = History(capacity: 120)
    private var lastTCP: TCPInfo?
    private var lastSample = Date()

    /// Development: pace writes to this many Mbps and treat the route as Wi-Fi
    public static var simulatedLinkMbps: Double?

    public init(target: DiscoveredReceiver, purpose: Purpose = .display, displaySize: DisplaySize = .standard) {
        self.target = target
        self.purpose = purpose
        self.displaySize = displaySize
    }

    /// Receiver panel brightness, 0…1
    public func setBrightness(_ level: Double) {
        connection?.send(Message(type: .brightness, payload: BrightnessWire.encode(level)))
    }

    /// Main queue: switches the virtual display's "looks like" size while streaming
    public func setDisplaySize(_ size: DisplaySize) {
        displaySize = size
        guard let display = display, let peer = snapshot.peer, display.setMode(points: size.points(for: peer.panelPoints)) else { return }
        // Cursor sizes are sent in stream pixels, which a new size changes
        cursor?.resendImage()
    }

    // MARK: - Lifecycle (main queue)

    public func start() {
        update { $0.state = "Finding a route" }
        let routes = RoutePlanner.plan(local: RoutePlanner.currentInterfaces(), remote: target.addresses)
        guard !routes.isEmpty else {
            return end(target.addresses.isEmpty ? "Receiver address unknown"
                       : "No Thunderbolt, USB, Ethernet or Wi-Fi route to \(target.name)")
        }
        connect(routes)
    }

    private func connect(_ routes: [Route]) {
        guard let route = routes.first else { return end("Could not reach \(target.name)") }
        update { $0.state = "Connecting via \(route.interface)" }
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
            $0.state = "Handshake"
        }
        let host = Host.current().localizedName ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        send(.hello, Hello(protocolVersion: AfterscreenProtocol.version, name: host, model: HardwareModel.identifier,
                           osVersion: "\(os.majorVersion).\(os.minorVersion)"))
    }

    public func stop(reason: String = "Stopped on the sender") {
        guard let c = connection, !ended else { return end(reason) }
        send(.bye, Bye(reason: reason))
        c.closeAfterFlush(reason: reason)
    }

    /// Pings and stats arrive at least twice a second on a live link
    static let idleTimeout: TimeInterval = 4

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
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
            guard let welcome = try? JSONWire.decode(Welcome.self, from: m.payload) else { return end("Bad welcome") }
            guard PathPolicy.isPlausible(welcome) else { return end("Receiver reported an invalid display size") }
            update { $0.peer = welcome }
            guard welcome.protocolVersion == AfterscreenProtocol.version else { return }
            update { $0.state = "Measuring the link" }
            probe()
        case .probeResult:
            guard let result = try? JSONWire.decode(ProbeResult.self, from: m.payload),
                  let welcome = snapshot.peer, let link = snapshot.link else { return }
            update { $0.capacityGbps = result.gbps }
            guard let config = PathPolicy.choose(link: link, capacityGbps: result.gbps, welcome: welcome) else {
                return end("Afterscreen supports Thunderbolt, USB, Ethernet and Wi-Fi links")
            }
            if purpose == .qualityTest { return startQualityTest(config) }
            send(.config, config)
            beginStreaming(config, welcome: welcome)
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
        case .bye:
            let reason = (try? JSONWire.decode(Bye.self, from: m.payload))?.reason ?? "Receiver stopped"
            end(reason)
        default:
            break
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
            $0.state = "Starting display"
        }
        do {
            let base = welcome.panelPoints
            display = try VirtualDisplay(name: "Afterscreen — \(welcome.name)", streamPixels: config.streamPixels, hiDPI: welcome.isRetina,
                                         modes: DisplaySize.allCases.map { $0.points(for: base) }, initial: displaySize.points(for: base))
        } catch {
            return end("\(error)")
        }
        guard let display = display, let connection = connection else { return }
        let streamer: FrameStreamer
        do {
            streamer = try FrameStreamer(config: config, capacityGbps: snapshot.capacityGbps, connection: connection)
        } catch {
            return end("\(error)")
        }
        self.streamer = streamer

        let cursor = CursorTracker(displayID: display.displayID)
        cursor.onPosition = { [weak self] x, y, visible in
            self?.connection?.send(Message(type: .cursorPos, payload: CursorWire.pos(x: x, y: y, visible: visible)))
        }
        cursor.onImage = { [weak self, weak display] image in
            guard let display = display else { return }
            // Points → stream pixels, so the receiver needs no display size
            let k = Double(config.streamPixels.width) / max(1, Double(display.bounds.width))
            func px(_ v: Int) -> Int { Int((Double(v) * k).rounded()) }
            self?.connection?.send(Message(type: .cursorImage, payload: CursorWire.image(width: px(image.width), height: px(image.height),
                                                                                          hotX: px(image.hotX), hotY: px(image.hotY), png: image.png)))
        }
        cursor.start()
        self.cursor = cursor

        let capture = Capture(displayID: display.displayID, size: config.streamPixels)
        capture.onFrame = { [weak streamer] frame in streamer?.offer(frame) }
        capture.onStop = { [weak self] reason in DispatchQueue.main.async { self?.end("Capture stopped: \(reason)") } }
        self.capture = capture
        capture.start { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.ended {
                    capture.stop()
                    return
                }
                if let error = error {
                    return self.end("Screen capture failed (\(error.localizedDescription)). Check Screen Recording permission.")
                }
                self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                      reason: "Streaming a display")
                self.update {
                    $0.isStreaming = true
                    $0.state = "Streaming"
                }
                self.startTimers()
            }
        }
    }

    private func startQualityTest(_ config: StreamConfig) {
        let stages = QualityTest.stages(panel: config.streamPixels).map { PathPolicy.stage(config, size: $0) }
        let path = config.video.map { "Tiles + \($0.codec.rawValue.uppercased()) for motion" } ?? "Tiles"
        let report = QualityTest.Report(receiver: snapshot.peer?.marketingName ?? target.name, link: snapshot.link, path: path)
        guard let connection = connection,
              let run = QualityTestRun(connection: connection, configs: stages, capacityGbps: snapshot.capacityGbps, report: report) else {
            return end("Quality test unavailable: Metal or the test pattern failed")
        }
        run.onReport = { [weak self] r in
            self?.update {
                $0.qualityTest = r
                $0.state = r.running.map { "Testing \(QualityTest.label($0))" } ?? "Test finished"
            }
        }
        run.onFinish = { [weak self] in
            guard let self = self else { return }
            let stages = (self.snapshot.qualityTest?.stages ?? []).map {
                String(format: "%@ %d×%d %.0f fps %.2f Gb/s", QualityTest.label($0.size), $0.size.width, $0.size.height, $0.fps, $0.gbps)
            }
            FileHandle.standardError.write(Data("[sender] quality test: \(stages.joined(separator: ", "))\n".utf8))
            self.stop(reason: "Quality test finished")
        }
        update { $0.config = config }
        testRun = run
        run.start()
    }

    // MARK: - Telemetry (main queue)

    /// Keeps the receiver's idle watchdog fed from the handshake on
    private func startPing() {
        let ping = DispatchSource.makeTimerSource(queue: .main)
        ping.schedule(deadline: .now(), repeating: .milliseconds(500))
        ping.setEventHandler { [weak self] in
            self?.connection?.send(Message(type: .ping, payload: PingWire.encode(DispatchTime.now().uptimeNanoseconds)))
        }
        ping.resume()
        timers.append(ping)
    }

    private func startTimers() {
        let sample = DispatchSource.makeTimerSource(queue: .main)
        sample.schedule(deadline: .now() + 1, repeating: 1)
        sample.setEventHandler { [weak self] in self?.sampleTelemetry() }
        sample.resume()
        timers.append(sample)
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
            $0.cpuPercent = m.cpuPercent
            $0.memoryBytes = m.memoryBytes
            $0.gpuPercent = streamer?.gpuMeter.percentSinceLastRead() ?? 0
        }
    }

    private func update(_ change: (inout SenderSnapshot) -> Void) {
        change(&snapshot)
        onUpdate?(snapshot)
    }

    private func send<T: Encodable>(_ type: MessageType, _ value: T) {
        guard let m = try? JSONWire.message(type, value) else { return }
        connection?.send(m)
    }
}
