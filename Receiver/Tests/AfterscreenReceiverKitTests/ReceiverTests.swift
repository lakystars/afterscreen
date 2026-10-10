import AfterscreenCore
import XCTest
@testable import AfterscreenReceiverKit

final class RenderGeometryTests: XCTestCase {
    func testLetterboxWhenViewIsTaller() {
        let r = RenderGeometry.aspectFit(content: CGSize(width: 2560, height: 1440), in: CGRect(x: 0, y: 0, width: 1960, height: 1240))
        XCTAssertEqual(r.width, 1960, accuracy: 0.01)
        XCTAssertEqual(r.height, 1102.5, accuracy: 0.01)
        XCTAssertEqual(r.minY, (1240 - 1102.5) / 2, accuracy: 0.01)
        XCTAssertEqual(r.minX, 0)
    }

    func testPillarboxWhenViewIsWider() {
        let r = RenderGeometry.aspectFit(content: CGSize(width: 1600, height: 1000), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(r.height, 1080, accuracy: 0.01)
        XCTAssertEqual(r.width, 1728, accuracy: 0.01)
        XCTAssertEqual(r.minX, 96, accuracy: 0.01)
    }

    func testExactFitAndEmptyContent() {
        let bounds = CGRect(x: 0, y: 0, width: 5120, height: 2880)
        XCTAssertEqual(RenderGeometry.aspectFit(content: CGSize(width: 2560, height: 1440), in: bounds), bounds)
        XCTAssertEqual(RenderGeometry.aspectFit(content: .zero, in: bounds), bounds)
    }
}

/// Records what the session asks the screen to do
final class FakeDisplay: StreamDisplay {
    let lock = NSLock()
    var begun: [StreamConfig] = []
    var ended: [String] = []
    var tiles: [Data] = []
    var presented: [Bool] = []
    var videoFrames = 0
    var log: [String] = []
    /// Set to hold showTiles until signalled
    var tileGate: DispatchSemaphore?
    var onEvent: (() -> Void)?
    let gpuMeter = GPUTimeMeter()
    var displayedFPS: Double { 0 }
    var lateFrames: Int { 0 }
    var uploadMs: Double { 0 }
    var decodeMs: Double { 0 }

    func read<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func record(_ body: () -> Void) {
        lock.lock(); body(); lock.unlock()
        onEvent?()
    }

    func begin(config: StreamConfig) { record { begun.append(config); log.append("begin") } }
    func prepare(config: StreamConfig) { record { log.append("prepare") } }
    func releaseDecodeResources() { record { log.append("release") } }
    func end(reason: String) { record { ended.append(reason) } }
    func showTiles(_ frame: TileFrame, present: Bool) -> Bool {
        guard let raw = try? frame.decodeAll() else { return false }
        record { tiles.append(raw); presented.append(present); log.append("tiles") }
        tileGate?.wait()
        return true
    }
    func setVideoParams(codec: VideoCodec, tenBit: Bool, parameterSets: [Data]) -> Bool { record { log.append("params") }; return true }
    func decodeVideo(avcc: Data) -> Bool { record { videoFrames += 1; log.append("video") }; return true }
    var brightness: Double? = 0.4
    var brightnessSet: [Double] = []
    var cursors: [Float] = []
    func setBrightness(_ level: Double) { record { brightnessSet.append(level) } }
    var audioPackets: [AudioWire.Packet] = []
    func playAudio(_ packet: AudioWire.Packet) { record { audioPackets.append(packet) } }
    var volume = 0.6
    var volumeSet: [Double] = []
    func setVolume(_ level: Double) { record { volumeSet.append(level) } }
    var debandSet: [Deband] = []
    func setDeband(_ level: Deband) { record { debandSet.append(level) } }
    var onRedrawNeeded: (() -> Void)?
    func redraw() { record { log.append("redraw") } }
    var audioBuffered: Double? { nil }
    var audioUnderruns: Int { 0 }
    func cursor(x: Float, y: Float, visible: Bool) { record { cursors.append(x) } }
    func cursorImage(_ image: CursorImage) {}
}

/// Stored tileFrame payload covering `runs` with `fill`
func tilePayload(_ g: TileGeometry, runs: [TileRun], fill: UInt8 = 7) -> (payload: Data, raw: Data) {
    let raw = Data(repeating: fill, count: runs.reduce(0) { $0 + $1.bytes(in: g) })
    return (TileFrame.header(frameIndex: 1, geometry: g, runs: runs, chunks: [(raw.count, 0)]) + raw, raw)
}

final class ReceiverSessionTests: XCTestCase {
    private let queue = DispatchQueue(label: "session-tests")
    private var listener: Listener!
    private var session: ReceiverSession!
    private var client: Connection!
    private let display = FakeDisplay()
    private var inbox: [Message] = []
    private var inboxWaiter: XCTestExpectation?

    private let welcome = Welcome(protocolVersion: AfterscreenProtocol.version, name: "iMac", modelID: "iMac18,3",
                                  marketingName: "iMac 27\" 5K (2017)", osVersion: "13.7", gpuNames: ["GPU"],
                                  panelPixels: PixelSize(width: 5120, height: 2880), panelPoints: PixelSize(width: 2560, height: 1440),
                                  hevcDecode: true, h264Decode: true, bc7: true)

    override func setUpWithError() throws {
        listener = try Listener()
        let accepted = expectation(description: "accept")
        listener.onAccept = { [unowned self] c in
            // As the app does: a connection during a session may be its cursor channel
            if let session = session { return session.offerChannel(c) }
            session = ReceiverSession(connection: c, hardware: welcome, display: display, idleTimeout: 1.5)
            session.start()
            accepted.fulfill()
        }
        listener.start()
        let connected = expectation(description: "connect")
        Connection.connect(host: "127.0.0.1", port: listener.port, interfaceName: nil, timeout: 2) { [unowned self] r in
            client = try? r.get()
            connected.fulfill()
        }
        wait(for: [accepted, connected], timeout: 3)
        client.onMessage = { [unowned self] m in
            guard m.type != .stats else { return }
            inbox.append(m)
            inboxWaiter?.fulfill()
        }
        client.start(queue: queue)
    }

    override func tearDown() {
        client?.close(reason: "test end")
        listener.stop()
    }

    private func expectReply(_ count: Int = 1, _ send: () -> Void) -> [Message] {
        let e = expectation(description: "reply")
        e.expectedFulfillmentCount = count
        queue.sync { inboxWaiter = e }
        send()
        wait(for: [e], timeout: 3)
        return queue.sync { () -> [Message] in
            defer { inbox.removeAll(); inboxWaiter = nil }
            return inbox
        }
    }

    private func waitForDisplay(_ condition: @escaping () -> Bool) {
        let e = expectation(description: "display")
        e.assertForOverFulfill = false
        let check = { [display] in
            display.lock.lock(); let ok = condition(); display.lock.unlock()
            if ok { e.fulfill() }
        }
        display.onEvent = check
        check()
        wait(for: [e], timeout: 3)
    }

    func testHelloGetsWelcome() throws {
        let replies = expectReply {
            client.send(try! JSONWire.message(.hello, Hello(protocolVersion: AfterscreenProtocol.version, name: "MBP", model: "Mac17,1", osVersion: "27")))
        }
        XCTAssertEqual(replies.first?.type, .welcome)
        var got = try JSONWire.decode(Welcome.self, from: replies[0].payload)
        XCTAssertNotEqual(got.channelToken, 0, "each session hands out a cursor channel token")
        got.channelToken = 0
        XCTAssertEqual(got, welcome)
    }

    func testVersionMismatchSaysBye() throws {
        let replies = expectReply(2) {
            client.send(try! JSONWire.message(.hello, Hello(protocolVersion: 999, name: "MBP", model: "x", osVersion: "27")))
        }
        XCTAssertEqual(replies.map(\.type), [.welcome, .bye])
    }

    func testConfigBeginsStream() {
        let config = StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128),
                                  video: nil, linkKind: .loopback)
        client.send(try! JSONWire.message(.config, config))
        waitForDisplay { [display] in display.begun == [config] }
    }

    func testTileFrameReachesDisplay() {
        let g = TileGeometry(width: 256, height: 128)
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1), TileRun(row: 1, first: 2, count: 2)])
        client.send(try! JSONWire.message(.config, StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128),
                                                                 video: nil, linkKind: .loopback)))
        client.send(Message(type: .tileFrame, payload: frame.payload))
        waitForDisplay { [display] in display.tiles.count == 1 }
        XCTAssertEqual(display.tiles.first, frame.raw)
    }

    func testBrightnessBeforeTheHandshakeIsIgnored() throws {
        client.send(Message(type: .brightness, payload: LevelWire.encode(0.1)))
        _ = try token()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(display.read { display.brightnessSet.isEmpty })
    }

    func testVolumeMessageSetsThePlaybackVolume() throws {
        _ = try token()
        client.send(Message(type: .volume, payload: LevelWire.encode(0.3)))
        waitForDisplay { [display] in !display.volumeSet.isEmpty }
        XCTAssertEqual(display.read { display.volumeSet.first } ?? 0, 0.3, accuracy: 1e-6)
    }

    func testARedrawRequestDrawsOnTheDecodeQueue() throws {
        _ = try token()
        let request = try XCTUnwrap(display.onRedrawNeeded, "the session asks the display for redraws")
        request()
        waitForDisplay { [display] in display.log.contains("redraw") }
    }

    func testDebandMessageSetsTheSmoothing() throws {
        _ = try token()
        client.send(Message(type: .deband, payload: DebandWire.encode(.strong)))
        waitForDisplay { [display] in !display.debandSet.isEmpty }
        XCTAssertEqual(display.read { display.debandSet }, [.strong])
        XCTAssertEqual(session.telemetry.deband, .strong, "the HUD shows the level in use")
    }

    func testSenderStatsReachTheHUD() throws {
        _ = try token()
        let stats = SenderStats(interface: "bridge0", mtu: 9000, capacityGbps: 12.4, throughputBitsPerSecond: 754e6,
                                latencyMs: 1, jitterMs: 0, retransmitPercent: 0, cableScore: 100,
                                captureFPS: 60, sentFPS: 60, droppedPerMinute: 0, dirtyPercent: 11, compressionRatio: 1,
                                encodeMs: 2.6, lossyTiles: 0, cpuPercent: 13, memoryBytes: 1 << 20, gpuPercent: 16)
        client.send(try JSONWire.message(.senderStats, stats))
        let deadline = Date().addingTimeInterval(3)
        while session.telemetry.sender == nil && Date() < deadline { usleep(10_000) }
        let t = session.telemetry
        XCTAssertEqual(t.sender, stats)
        XCTAssertEqual(t.throughput.values, [754e6])
        XCTAssertEqual(t.latency.values, [1])
    }

    func testStopOnTheReceiverAsksTheSenderNotToReconnect() throws {
        let replies = expectReply { session.stop(reason: "Stopped on the receiver", pause: true) }
        let bye = try JSONWire.decode(Bye.self, from: try XCTUnwrap(replies.first).payload)
        XCTAssertEqual(bye, Bye(reason: "Stopped on the receiver", pause: true))
    }

    func testBrightnessMessageSetsThePanel() throws {
        _ = try token()
        client.send(Message(type: .brightness, payload: LevelWire.encode(0.8)))
        waitForDisplay { [display] in !display.brightnessSet.isEmpty }
        XCTAssertEqual(display.read { display.brightnessSet.first } ?? 0, 0.8, accuracy: 1e-6)
    }

    func testStatsReportBrightness() throws {
        let e = expectation(description: "stats")
        e.assertForOverFulfill = false
        var stats: ReceiverStats?
        client.onMessage = { m in
            guard m.type == .stats else { return }
            stats = try? JSONWire.decode(ReceiverStats.self, from: m.payload)
            e.fulfill()
        }
        client.send(try! JSONWire.message(.config, tileConfig))
        wait(for: [e], timeout: 3)
        XCTAssertEqual(stats?.brightness, 0.4)
        XCTAssertEqual(stats?.volume, 0.6)
        XCTAssertEqual(session.telemetry.receiver, stats, "the HUD shows what the sender is told")
        XCTAssertEqual(session.telemetry.shownFPS.values.count, 1)
    }

    private func token() throws -> UInt32 {
        let replies = expectReply {
            client.send(try! JSONWire.message(.hello, Hello(protocolVersion: AfterscreenProtocol.version, name: "MBP", model: "Mac17,1", osVersion: "27")))
        }
        return try JSONWire.decode(Welcome.self, from: try XCTUnwrap(replies.first).payload).channelToken
    }

    private func channel(_ token: UInt32) throws -> Connection {
        var c: Connection?
        let connected = expectation(description: "channel")
        Connection.connect(host: "127.0.0.1", port: listener.port, interfaceName: nil, timeout: 2) { c = try? $0.get(); connected.fulfill() }
        wait(for: [connected], timeout: 3)
        let channel = try XCTUnwrap(c)
        channel.start(queue: queue)
        channel.send(Message(type: .cursorChannel, payload: ChannelWire.encode(token)))
        return channel
    }

    func testCursorChannelDeliversWhileFramesBackUp() throws {
        let channel = try channel(try token())
        defer { channel.close(reason: "test end") }
        let g = TileGeometry(width: 256, height: 128)
        let gate = DispatchSemaphore(value: 0)
        display.tileGate = gate
        client.send(try! JSONWire.message(.config, tileConfig))
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1)]).payload
        for _ in 0..<10 { client.send(Message(type: .tileFrame, payload: frame)) }
        waitForDisplay { [display] in display.tiles.count == 1 }
        // The main connection is held behind the blocked screen; the cursor is not
        channel.send(Message(type: .cursorPos, payload: CursorWire.pos(x: 0.25, y: 0.5, visible: true)))
        waitForDisplay { [display] in display.cursors == [0.25] }
        XCTAssertEqual(display.read { display.tiles.count }, 1)
        display.tileGate = nil
        for _ in 0..<10 { gate.signal() }
    }

    func testSoundOnTheChannelReachesTheSpeakers() throws {
        let channel = try channel(try token())
        defer { channel.close(reason: "test end") }
        channel.send(Message(type: .audio, payload: AudioWire.encode(sampleRate: 48_000, channels: 2, samples: [1, 2, 3, 4])))
        waitForDisplay { [display] in display.audioPackets.count == 1 }
        XCTAssertEqual(display.read { display.audioPackets.first?.samples }, [1, 2, 3, 4])
    }

    func testChannelWithAnotherTokenIsRefused() throws {
        let good = try token()
        let channel = try channel(good &+ 1)
        let closed = expectation(description: "closed")
        channel.onClose = { _ in closed.fulfill() }
        wait(for: [closed], timeout: 3)
        channel.send(Message(type: .cursorPos, payload: CursorWire.pos(x: 0.75, y: 0.5, visible: true)))
        XCTAssertTrue(display.read { display.cursors.isEmpty })
    }

    func testPingEchoesAsPong() throws {
        let replies = expectReply { client.send(Message(type: .ping, payload: PingWire.encode(42))) }
        XCTAssertEqual(replies.first?.type, .pong)
        XCTAssertEqual(try PingWire.decode(replies[0].payload), 42)
    }

    func testProbeReportsBytesAfterEndMarker() throws {
        let replies = expectReply {
            for _ in 0..<4 { client.send(Message(type: .probe, payload: Data(count: 1 << 20))) }
            client.send(Message(type: .probe, flags: ProbeFlags.end, payload: Data()))
        }
        let result = try JSONWire.decode(ProbeResult.self, from: try XCTUnwrap(replies.first).payload)
        XCTAssertEqual(replies.first?.type, .probeResult)
        XCTAssertEqual(result.bytes, 4 << 20)
        XCTAssertGreaterThan(result.seconds, 0)
    }

    private let tileConfig = StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128),
                                          video: nil, linkKind: .loopback)

    private func expectEnd(_ send: () -> Void) -> String {
        let ended = expectation(description: "ended")
        var reason = ""
        session.onEnd = { reason = $0; ended.fulfill() }
        send()
        wait(for: [ended], timeout: 4)
        return reason
    }

    func testSilentSenderEndsSession() {
        let reason = expectEnd {}
        XCTAssertTrue(reason.contains("no data"), reason)
    }

    private let hybridConfig = StreamConfig(path: .hybrid, streamPixels: PixelSize(width: 256, height: 128),
                                            video: VideoLayer(codec: .hevc, pixels: PixelSize(width: 192, height: 96), bitrate: 20_000_000),
                                            linkKind: .wifi)

    func testConfigResetsDecoderBeforeVideoParams() {
        client.send(try! JSONWire.message(.config, hybridConfig))
        client.send(Message(type: .videoParams, payload: VideoWire.params(codec: .hevc, sets: [Data([1]), Data([2]), Data([3])])))
        waitForDisplay { [display] in display.log.contains("params") && display.log.contains("begin") }
        let log = display.read { display.log }
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "prepare")), try XCTUnwrap(log.firstIndex(of: "params")), "\(log)")
    }

    func testHybridVideoFrameDecodesAndTheTileFrameAfterItPresents() {
        let g = TileGeometry(width: 256, height: 128)
        client.send(try! JSONWire.message(.config, hybridConfig))
        client.send(Message(type: .videoParams, payload: VideoWire.params(codec: .hevc, sets: [Data([1])])))
        client.send(Message(type: .videoFrame, payload: VideoWire.frame(keyframe: true, avcc: Data([0, 0, 0, 1, 9]))))
        client.send(Message(type: .tileFrame, payload: tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 2, format: .video)]).payload))
        waitForDisplay { [display] in display.tiles.count == 1 }
        XCTAssertEqual(display.read { display.log.filter { $0 != "begin" } }, ["prepare", "params", "video", "tiles"])
    }

    func testVideoFrameOnTheTilePathEndsSession() {
        let reason = expectEnd {
            client.send(try! JSONWire.message(.config, tileConfig))
            client.send(Message(type: .videoFrame, payload: VideoWire.frame(keyframe: true, avcc: Data([1]))))
        }
        XCTAssertTrue(reason.contains("hybrid"), reason)
        XCTAssertEqual(display.read { display.videoFrames }, 0)
    }

    func testTileFrameForAnotherGeometryEndsSession() {
        let other = TileGeometry(width: 512, height: 128)
        _ = expectEnd {
            client.send(try! JSONWire.message(.config, tileConfig))
            client.send(Message(type: .tileFrame, payload: tilePayload(other, runs: [TileRun(row: 0, first: 0, count: 1)]).payload))
        }
        XCTAssertTrue(display.read { display.tiles.isEmpty })
    }

    func testImplausibleConfigEndsSession() {
        var bad = tileConfig
        bad.streamPixels = PixelSize(width: 100_000, height: 128)
        _ = expectEnd { client.send(try! JSONWire.message(.config, bad)) }
        XCTAssertTrue(display.read { display.begun.isEmpty })
    }

    func testReadingPausesWhileTheScreenIsBehind() {
        let g = TileGeometry(width: 256, height: 128)
        let gate = DispatchSemaphore(value: 0)
        display.tileGate = gate
        client.send(try! JSONWire.message(.config, tileConfig))
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1)]).payload
        for _ in 0..<10 { client.send(Message(type: .tileFrame, payload: frame)) }
        waitForDisplay { [display] in display.tiles.count == 1 }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertLessThanOrEqual(session.framesInFlight, ReceiverSession.maxFramesInFlight)
        display.tileGate = nil
        for _ in 0..<10 { gate.signal() }
        waitForDisplay { [display] in display.tiles.count == 10 }
    }

    func testFramesWithMoreBehindThemUploadWithoutPresenting() {
        let g = TileGeometry(width: 256, height: 128)
        let gate = DispatchSemaphore(value: 0)
        display.tileGate = gate
        client.send(try! JSONWire.message(.config, tileConfig))
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1)]).payload
        for _ in 0..<3 { client.send(Message(type: .tileFrame, payload: frame)) }
        waitForDisplay { [display] in display.tiles.count == 1 }
        Thread.sleep(forTimeInterval: 0.2)
        display.tileGate = nil
        for _ in 0..<3 { gate.signal() }
        waitForDisplay { [display] in display.tiles.count == 3 }
        // The display presents at its refresh rate; a frame with others queued behind it only updates the texture
        XCTAssertEqual(display.read { Array(display.presented.suffix(2)) }, [false, true])
    }

    func testSessionEndingWithFramesInFlightIsReleasedCleanly() {
        let g = TileGeometry(width: 256, height: 128)
        let gate = DispatchSemaphore(value: 0)
        display.tileGate = gate
        client.send(try! JSONWire.message(.config, tileConfig))
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1)]).payload
        for _ in 0..<5 { client.send(Message(type: .tileFrame, payload: frame)) }
        waitForDisplay { [display] in display.tiles.count == 1 }
        _ = expectEnd { client.close(reason: "gone") }
        weak var released = session
        session = nil
        display.tileGate = nil
        for _ in 0..<5 { gate.signal() }
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertNil(released)
    }

    func testEndingTheSessionReleasesDecodeResources() {
        client.send(try! JSONWire.message(.config, tileConfig))
        waitForDisplay { [display] in display.log.contains("prepare") }
        _ = expectEnd { client.close(reason: "gone") }
        waitForDisplay { [display] in display.log.contains("release") }
    }

    func testTruncatedTileFrameEndsSession() {
        let ended = expectation(description: "ended")
        session.onEnd = { _ in ended.fulfill() }
        client.send(Message(type: .tileFrame, payload: Data([1, 2, 3])))
        wait(for: [ended], timeout: 3)
    }
}

final class HardwareInfoTests: XCTestCase {
    func testNativePanelIgnoresScaledModesWithLargerBacking() {
        let modes = [
            DisplayModeInfo(width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338, isNative: false),
            DisplayModeInfo(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, isNative: false),
            DisplayModeInfo(width: 3024, height: 1964, pixelWidth: 3024, pixelHeight: 1964, isNative: true),
        ]
        XCTAssertEqual(HardwareInfo.nativePanel(modes), PixelSize(width: 3024, height: 1964))
    }

    func testNativePanelFallsBackToLargestOneToOneMode() {
        let modes = [
            DisplayModeInfo(width: 3200, height: 1800, pixelWidth: 6400, pixelHeight: 3600, isNative: false),
            DisplayModeInfo(width: 5120, height: 2880, pixelWidth: 5120, pixelHeight: 2880, isNative: false),
            DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, isNative: false),
        ]
        XCTAssertEqual(HardwareInfo.nativePanel(modes), PixelSize(width: 5120, height: 2880))
        XCTAssertNil(HardwareInfo.nativePanel([]))
    }

    func testMarketingNames() {
        XCTAssertEqual(HardwareInfo.marketingName(modelID: "iMac14,2"), "iMac 27\" (Late 2013)")
        XCTAssertEqual(HardwareInfo.marketingName(modelID: "iMac18,3"), "iMac 27\" 5K (2017)")
        XCTAssertEqual(HardwareInfo.marketingName(modelID: "Mac17,9"), "Mac17,9")
    }

    func testPanelPointsHalfOnRetina() {
        XCTAssertEqual(HardwareInfo.points(forPanel: PixelSize(width: 5120, height: 2880)), PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(HardwareInfo.points(forPanel: PixelSize(width: 4096, height: 2304)), PixelSize(width: 2048, height: 1152))
        XCTAssertEqual(HardwareInfo.points(forPanel: PixelSize(width: 2560, height: 1440)), PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(HardwareInfo.points(forPanel: PixelSize(width: 3600, height: 2338)), PixelSize(width: 1800, height: 1169))
    }

    func testMain10ProbeFindsTheHardwareDecoder() {
        #if arch(arm64)
        XCTAssertTrue(HardwareInfo.hevcMain10Decode, "every Apple silicon Mac decodes Main10")
        #endif
        XCTAssertEqual(HardwareInfo.welcome(name: "test").hevcMain10Decode, HardwareInfo.hevcMain10Decode)
    }

    func testWelcomeDescribesThisMac() {
        let w = HardwareInfo.welcome(name: "test")
        XCTAssertEqual(w.protocolVersion, AfterscreenProtocol.version)
        XCTAssertGreaterThan(w.panelPixels.width, 0)
        XCTAssertFalse(w.modelID.isEmpty)
        XCTAssertFalse(w.gpuNames.isEmpty)
    }
}

import Metal

final class TileTextureTests: XCTestCase {
    /// Reads a texture back through the sampler as RGBA8
    private func readBack(_ tex: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void rb(texture2d<float> src [[texture(0)]], device uchar4 *out [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
            uint w = src.get_width(), h = src.get_height();
            if (gid.x >= w || gid.y >= h) return;
            constexpr sampler s(coord::pixel, filter::nearest);
            out[gid.y * w + gid.x] = uchar4(round(saturate(src.sample(s, float2(gid) + 0.5)) * 255.0));
        }
        """
        let lib = try device.makeLibrary(source: source, options: nil)
        let pso = try device.makeComputePipelineState(function: lib.makeFunction(name: "rb")!)
        let out = device.makeBuffer(length: tex.width * tex.height * 4, options: .storageModeShared)!
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: tex.width, height: tex.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt8.self), count: tex.width * tex.height * 4))
    }

    /// One flat block per position: R = block x, G = block y, B = `blue` (7-bit endpoints, p-bit 0)
    private func runData(_ g: TileGeometry, _ run: TileRun, blue: UInt8) -> Data {
        var data = Data()
        let b = run.blocks(in: g)
        for y in 0..<b.h {
            for x in 0..<b.w {
                let bx = UInt8(run.first * g.tileBlocks + x), by = UInt8(run.row * g.tileBlocks + y)
                data.append(contentsOf: BC7.makeMode6(e0: (bx, by, blue, 127), e1: (bx, by, blue, 127), p0: 0, p1: 0,
                                                      indices: [UInt8](repeating: 0, count: 16)))
            }
        }
        return data
    }

    func testRunsLandAtTheirPositionsIncludingPartialEdge() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 128, height: 96) // 2×2 tiles, bottom row 32 px tall
        let runs = [TileRun(row: 0, first: 1, count: 1), TileRun(row: 1, first: 0, count: 2)]
        let raw = runData(g, runs[0], blue: 10) + runData(g, runs[1], blue: 30)
        let half = raw.count / 2 / 16 * 16
        var lz4 = Data(count: LZ4.bound(half))
        let n = try XCTUnwrap(lz4.withUnsafeMutableBytes { dst in
            raw.prefix(half).withUnsafeBytes { LZ4.encode($0, into: dst.baseAddress!, capacity: dst.count) }
        })
        lz4.count = n
        let payload = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(half, n), (raw.count - half, 0)])
            + lz4 + raw.suffix(from: half)
        let tt = TileTexture(device: device)
        tt.ensure(geometry: g)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try tt.encodeUpload(try TileFrame(payload: payload, expecting: g), into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        let rgba = try readBack(try XCTUnwrap(tt.texture), device: device)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * g.width + x) * 4..<(y * g.width + x) * 4 + 3]) }
        // Run 0 (top-right tile), block (18, 3)
        XCTAssertEqual(pixel(18 * 4 + 1, 3 * 4 + 2), [36, 6, 20])
        // Run 1 (bottom row, partial height), block (5, 23)
        XCTAssertEqual(pixel(5 * 4, 23 * 4 + 3), [10, 46, 60])
        // Last pixel
        XCTAssertEqual(pixel(127, 95), [62, 46, 60])
    }

    func testStoredFrameInPageAlignedMemoryUploadsWithoutStaging() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 128, height: 96)
        let runs = [TileRun(row: 1, first: 0, count: 2), TileRun(row: 0, first: 0, count: 1)]
        let raw = runData(g, runs[0], blue: 40) + runData(g, runs[1], blue: 50)
        let bytes = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(raw.count, 0)]) + raw
        let aligned = BufferPool(keep: 1).data(capacity: bytes.count) { dst in
            bytes.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return bytes.count
        }
        XCTAssertEqual(aligned.withUnsafeBytes { Int(bitPattern: $0.baseAddress!) } % Int(getpagesize()), 0)
        let tt = TileTexture(device: device)
        tt.ensure(geometry: g)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try tt.encodeUpload(try TileFrame(payload: aligned, expecting: g), into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        let rgba = try readBack(try XCTUnwrap(tt.texture), device: device)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * g.width + x) * 4..<(y * g.width + x) * 4 + 3]) }
        XCTAssertEqual(pixel(5 * 4, 23 * 4 + 3), [10, 46, 80])
        XCTAssertEqual(pixel(127, 95), [62, 46, 80])
        XCTAssertEqual(pixel(15 * 4, 15 * 4), [30, 30, 100])
    }

    func testPooledPayloadIsWrappedOnce() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 128, height: 96)
        let runs = [TileRun(row: 0, first: 0, count: 2)]
        let raw = runData(g, runs[0], blue: 9)
        let bytes = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(raw.count, 0)]) + raw
        let tt = TileTexture(device: device)
        tt.ensure(geometry: g)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for _ in 0..<3 {
            let payload = BufferPool.shared.data(capacity: 3 << 20) { dst in
                bytes.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                return bytes.count
            }
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            try tt.encodeUpload(try TileFrame(payload: payload, expecting: g), into: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        XCTAssertEqual(tt.wrappedBuffers, 1)
    }

    /// 565 endpoints and 2-bit indices; colours expand by bit replication
    private func bc1(_ c0: UInt16, _ c1: UInt16, indices: UInt32) -> Data {
        var d = Data()
        withUnsafeBytes(of: (UInt32(c0) | UInt32(c1) << 16).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: indices.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    func testBC1RunsAreTranscodedIntoTheBC7Texture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 64, height: 64)
        let run = TileRun(row: 0, first: 0, count: 1, format: .bc1)
        // red (31,0,0) and blue (0,0,31); pixel 0 → c0, 1 → c1, 2 → 1/3, 3 → 2/3, the rest c0
        let block = bc1(0xF800, 0x001F, indices: 0b11_10_01_00)
        let raw = (0..<(16 * 16)).reduce(Data()) { d, _ in d + block }
        let payload = TileFrame.header(frameIndex: 0, geometry: g, runs: [run], chunks: [(raw.count, 0)]) + raw
        let tt = TileTexture(device: device)
        tt.ensure(geometry: g)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try tt.encodeUpload(try TileFrame(payload: payload, expecting: g), into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        let rgba = try readBack(try XCTUnwrap(tt.texture), device: device)
        func pixel(_ x: Int, _ y: Int) -> [Int] { rgba[(y * g.width + x) * 4..<(y * g.width + x) * 4 + 3].map(Int.init) }
        func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
        XCTAssertTrue(near(pixel(0, 0), [255, 0, 0]), "\(pixel(0, 0))")
        XCTAssertTrue(near(pixel(1, 0), [0, 0, 255]), "\(pixel(1, 0))")
        XCTAssertTrue(near(pixel(2, 0), [171, 0, 84]), "\(pixel(2, 0))")   // 21/64 toward blue
        XCTAssertTrue(near(pixel(3, 0), [84, 0, 171]), "\(pixel(3, 0))")   // 43/64 toward blue
        XCTAssertTrue(near(pixel(63, 63), [255, 0, 0]), "\(pixel(63, 63))")
    }

    func testCorruptChunkFailsAndLeavesTheTextureUsable() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 64, height: 64)
        let run = TileRun(row: 0, first: 0, count: 1)
        let raw = runData(g, run, blue: 5)
        let bad = TileFrame.header(frameIndex: 0, geometry: g, runs: [run], chunks: [(raw.count, 100)]) + Data(repeating: 0xF0, count: 100)
        let good = TileFrame.header(frameIndex: 0, geometry: g, runs: [run], chunks: [(raw.count, 0)]) + raw
        let tt = TileTexture(device: device)
        tt.ensure(geometry: g)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for _ in 0..<4 {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertThrowsError(try tt.encodeUpload(try TileFrame(payload: bad, expecting: g), into: cb))
            cb.commit()
        }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try tt.encodeUpload(try TileFrame(payload: good, expecting: g), into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(try readBack(try XCTUnwrap(tt.texture), device: device)[0..<3], [0, 0, 10])
    }
}

final class StreamRendererTests: XCTestCase {
    func testShadersCompileAndPipelinesBuild() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNotNil(StreamRenderer(device: device))
    }

    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ w: Int, _ h: Int, _ texel: [UInt8]) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        let t = device.makeTexture(descriptor: desc)!
        let bytes = (0..<(w * h)).flatMap { _ in texel }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * texel.count)
        return t
    }

    func testHybridFragmentShowsVideoOnlyInMaskedTiles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: StreamRenderer.shaders, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screenQuad")
        desc.fragmentFunction = library.makeFunction(name: "hybridFragment")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let target = texture(device, .rgba8Unorm, 128, 64, [0, 0, 0, 0])
        let tiles = texture(device, .rgba8Unorm, 128, 64, [255, 0, 0, 255])
        // Video layer at half size: white (Y 235, Cb = Cr = 128)
        let luma = texture(device, .r8Unorm, 64, 32, [235])
        let chroma = texture(device, .rg8Unorm, 32, 16, [128, 128])
        let mask = try XCTUnwrap(device.makeBuffer(bytes: [UInt8(1), 0], length: 2, options: .storageModeShared))
        var grid: [UInt32] = [2, 64, 128, 64]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tiles, index: 0)
        enc.setFragmentTexture(luma, index: 1)
        enc.setFragmentTexture(chroma, index: 2)
        enc.setFragmentBuffer(mask, offset: 0, index: 0)
        enc.setFragmentBytes(&grid, length: 16, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: 128 * 64 * 4)
        target.getBytes(&pixels, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 64), mipmapLevel: 0)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 128 + x) * 4..<(y * 128 + x) * 4 + 3]) }
        XCTAssertEqual(pixel(10, 30), [255, 255, 255], "masked tile shows the video")
        XCTAssertEqual(pixel(63, 63), [255, 255, 255])
        XCTAssertEqual(pixel(64, 0), [255, 0, 0], "unmasked tile shows the tiles")
        XCTAssertEqual(pixel(127, 63), [255, 0, 0])
    }
}

final class UpscaleTests: XCTestCase {
    /// Grey levels (w × 16) through `tileFragment` into a float target `scale` times wider; red per pixel of row 8, 0…255
    private func upscaled(_ levels: [UInt8], width w: Int, scale: Double) throws -> [Float] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: StreamRenderer.shaders, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screenQuad")
        desc.fragmentFunction = library.makeFunction(name: "tileFragment")
        desc.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let h = 16, tw = Int(Double(w) * scale), th = Int(Double(h) * scale)
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        sd.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sd))
        let rgba: [UInt8] = (0..<(w * h)).flatMap { i -> [UInt8] in let v = levels[i % w]; return [v, v, v, 255] }
        source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rgba, bytesPerRow: w * 4)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: tw, height: th, mipmapped: false)
        td.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: tw * th * 4)
        target.getBytes(&out, bytesPerRow: tw * 16, from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        return (0..<tw).map { out[((th / 2) * tw + $0) * 4] * 255 }
    }

    func testEdgesStaySharperThanBilinearWhenScaledUp() throws {
        // Black to white at texel 32; at 1.25× pixels 39 and 40 straddle it (bilinear: 25.5 → 229.5)
        let row = try upscaled((0..<64).map { $0 < 32 ? 0 : 255 }, width: 64, scale: 1.25)
        XCTAssertGreaterThan(row[40] - row[39], 215)
        XCTAssertEqual(row[10], 0, accuracy: 0.5)
        XCTAssertEqual(row[70], 255, accuracy: 0.5)
    }

    func testVideoEdgesStaySharperThanBilinearWhenScaledUp() throws {
        // Video luma black (16) to white (235) at texel 32 of 64, drawn 2× into masked tiles (bilinear: 63.75 → 191.25)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: StreamRenderer.shaders, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screenQuad")
        desc.fragmentFunction = library.makeFunction(name: "hybridFragment")
        desc.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: [UInt8], _ bpp: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]
            let t = try XCTUnwrap(device.makeTexture(descriptor: d))
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * bpp)
            return t
        }
        let tiles = try texture(.rgba8Unorm, 128, 64, [UInt8](repeating: 0, count: 128 * 64 * 4), 4)
        let luma = try texture(.r8Unorm, 64, 32, (0..<(64 * 32)).map { $0 % 64 < 32 ? 16 : 235 }, 1)
        let chroma = try texture(.rg8Unorm, 32, 16, [UInt8](repeating: 128, count: 32 * 16 * 2), 2)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 128, height: 64, mipmapped: false)
        td.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let mask = try XCTUnwrap(device.makeBuffer(bytes: [UInt8(1), 1], length: 2, options: .storageModeShared))
        var grid: [UInt32] = [2, 64, 128, 64]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tiles, index: 0)
        enc.setFragmentTexture(luma, index: 1)
        enc.setFragmentTexture(chroma, index: 2)
        enc.setFragmentBuffer(mask, offset: 0, index: 0)
        enc.setFragmentBytes(&grid, length: 16, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: 128 * 64 * 4)
        target.getBytes(&out, bytesPerRow: 128 * 16, from: MTLRegionMake2D(0, 0, 128, 64), mipmapLevel: 0)
        let row = (0..<128).map { out[(32 * 128 + $0) * 4] * 255 }
        XCTAssertGreaterThan(row[64] - row[63], 140)
        XCTAssertEqual(row[10], 0, accuracy: 0.5)
        XCTAssertEqual(row[110], 255, accuracy: 0.5)
    }

    func testFlatAreasStayFlatWhenScaledUp() throws {
        let row = try upscaled([UInt8](repeating: 77, count: 64), width: 64, scale: 1.25)
        XCTAssertLessThan(row.map { abs($0 - 77) }.max() ?? 1, 0.5)
    }
}

final class DebandCacheTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: DebandCache!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = try XCTUnwrap(DebandCache(device: device))
    }

    /// Grey levels (8-bit) as an RGBA texture
    private func source(_ levels: [UInt8], _ w: Int, _ h: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        let t = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let rgba: [UInt8] = levels.flatMap { [$0, $0, $0, 255] }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rgba, bytesPerRow: w * 4)
        return t
    }

    /// Updates the cache and draws what the screen would show through `tileFragment`; red per pixel, 0…255
    private func shown(_ src: MTLTexture, _ g: TileGeometry, _ level: Deband) throws -> [Float] {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let picture = cache.update(source: src, geometry: g, range: level.rangePixels, into: cb) ?? src
        let library = try device.makeLibrary(source: StreamRenderer.shaders, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screenQuad")
        desc.fragmentFunction = library.makeFunction(name: "tileFragment")
        desc.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: g.width, height: g.height, mipmapped: false)
        td.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(picture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: g.width * g.height * 4)
        target.getBytes(&out, bytesPerRow: g.width * 16, from: MTLRegionMake2D(0, 0, g.width, g.height), mipmapLevel: 0)
        return stride(from: 0, to: out.count, by: 4).map { out[$0] * 255 }
    }

    /// Levels 18…21 in 128-pixel bands: a dark gradient drawn without dither
    private let bandW = 512, bandH = 64
    private var bands: [UInt8] { (0..<(bandW * bandH)).map { UInt8(18 + ($0 % bandW) / 128) } }

    /// Columns whose mean sits between the levels either side of the step at x = 256: 0 for an untouched step
    private func rampWidth(_ out: [Float]) -> Int {
        (128..<384).filter { x in
            let mean = (0..<bandH).reduce(Float(0)) { $0 + out[$1 * bandW + x] } / Float(bandH)
            return mean > 19.1 && mean < 19.9
        }.count
    }

    func testSingleLevelStepsInFlatAreasBecomeRamps() throws {
        let g = TileGeometry(width: bandW, height: bandH)
        let out = try shown(try source(bands, bandW, bandH), g, .weak)
        let profile = (0..<bandW).map { x in (0..<bandH).reduce(Float(0)) { $0 + out[$1 * bandW + x] } / Float(bandH) }
        let steepest = zip(profile, profile.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        XCTAssertLessThan(steepest, 0.35, "a one-level step spreads over a ramp")
        let mean = out.reduce(0, +) / Float(out.count), sourceMean = Float(bands.reduce(0) { $0 + Int($1) }) / Float(bands.count)
        XCTAssertEqual(mean, sourceMean, accuracy: 0.05, "brightness unchanged")
    }

    func testOffDrawsTheSourceAndStrongerSpreadsWider() throws {
        let g = TileGeometry(width: bandW, height: bandH)
        let src = try source(bands, bandW, bandH)
        let off = try shown(src, g, .off)
        XCTAssertEqual(zip(off, bands).map { abs($0 - Float($1)) }.max() ?? 1, 0, accuracy: 0.001)
        let weak = rampWidth(try shown(src, g, .weak))
        let strong = rampWidth(try shown(src, g, .strong))
        XCTAssertGreaterThan(weak, 16)
        XCTAssertGreaterThan(Double(strong), Double(weak) * 1.5)
    }

    func testEdgesAndFlatAreasStayWithinTenBitPrecision() throws {
        // Dark and light halves with a one-pixel line: every difference is far past one level
        let w = 256, h = 64
        let levels = (0..<(w * h)).map { i -> UInt8 in
            let x = i % w
            return x == 64 ? 60 : (x < 128 ? 20 : 200)
        }
        let out = try shown(try source(levels, w, h), TileGeometry(width: w, height: h), .strong)
        XCTAssertLessThan(zip(out, levels).map { abs($0 - Float($1)) }.max() ?? 1, 0.13)
    }

    func testOnlyMarkedTilesAndTheirReachAreRecomputed() throws {
        // 8 tiles in a row; low reaches one tile
        let g = TileGeometry(width: 512, height: 64)
        let src = try source([UInt8](repeating: 100, count: 512 * 64), 512, 64)
        _ = try shown(src, g, .weak)
        let brighter: [UInt8] = [UInt8](repeating: 150, count: 512 * 64).flatMap { [$0, $0, $0, 255] }
        src.replace(region: MTLRegionMake2D(0, 0, 512, 64), mipmapLevel: 0, withBytes: brighter, bytesPerRow: 512 * 4)
        cache.mark([TileRun(row: 0, first: 0, count: 1)], geometry: g)
        let out = try shown(src, g, .weak)
        func tile(_ i: Int) -> Float { out[32 * 512 + i * 64 + 32] }
        XCTAssertEqual(tile(0), 150, accuracy: 0.2, "the changed tile")
        XCTAssertEqual(tile(1), 150, accuracy: 0.2, "within reach of it")
        XCTAssertEqual(tile(7), 100, accuracy: 0.2, "out of reach: kept from before")
        XCTAssertEqual(try shown(src, g, .strong)[32 * 512 + 7 * 64 + 32], 150, accuracy: 0.2, "a new level recomputes all")
    }

    func testReachGrowsMarksByTheMarginWithinTheGrid() {
        var marks = [Bool](repeating: false, count: 4 * 3)
        marks[1 * 4 + 1] = true
        XCTAssertEqual(DebandCache.reach(marks, tilesX: 4, tilesY: 3, margin: 1), [0, 1, 2, 4, 5, 6, 8, 9, 10])
        XCTAssertEqual(DebandCache.reach(marks, tilesX: 4, tilesY: 3, margin: 0), [5])
        marks = [Bool](repeating: false, count: 4 * 3)
        marks[11] = true
        XCTAssertEqual(DebandCache.reach(marks, tilesX: 4, tilesY: 3, margin: 1), [6, 7, 10, 11])
    }
}

final class VideoMaskTests: XCTestCase {
    private let g = TileGeometry(width: 256, height: 128) // 4×2 tiles

    func testVideoRunsSetTilesAndTileRunsClearThem() {
        var mask = VideoMask()
        mask.apply([TileRun(row: 0, first: 1, count: 3, format: .video), TileRun(row: 1, first: 0, count: 1, format: .video)], geometry: g)
        XCTAssertEqual(mask.bytes, [0, 1, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(mask.shown, 4)
        mask.apply([TileRun(row: 0, first: 2, count: 1), TileRun(row: 1, first: 0, count: 2, format: .bc1)], geometry: g)
        XCTAssertEqual(mask.bytes, [0, 1, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(mask.shown, 2)
        mask.apply([TileRun(row: 0, first: 1, count: 1, format: .video)], geometry: g)
        XCTAssertEqual(mask.shown, 2, "a tile already on video is not counted twice")
    }

    func testNewGeometryOrResetClearsTheMask() {
        var mask = VideoMask()
        mask.apply([TileRun(row: 0, first: 0, count: 4, format: .video)], geometry: g)
        mask.apply([], geometry: TileGeometry(width: 128, height: 128))
        XCTAssertEqual(mask.bytes, [0, 0, 0, 0])
        XCTAssertEqual(mask.shown, 0)
        mask.apply([TileRun(row: 0, first: 0, count: 1, format: .video)], geometry: g)
        mask.reset()
        XCTAssertEqual(mask.shown, 0)
        XCTAssertTrue(mask.bytes.isEmpty)
    }
}

final class ScreenSnapshotTests: XCTestCase {
    func testTenBitWordsBecomeSixteenBitRGBInTheDrawablesLayout() throws {
        // What the GPU writes for pure red into the drawable format
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: StreamRenderer.drawableFormat, width: 4, height: 4, mipmapped: false)
        desc.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var words = [UInt32](repeating: 0, count: 16)
        target.getBytes(&words, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        let rgb = ScreenSnapshot.rgb16(fromBGR10A2: words)
        XCTAssertEqual(rgb.count, 16 * 3)
        XCTAssertEqual(rgb[0], 65535)
        XCTAssertEqual(Double(rgb[1]), 32768, accuracy: 64)
        XCTAssertEqual(rgb[2], 0)
    }

    func testWritesASixteenBitPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let words = [UInt32](repeating: 3 << 30 | 1023 << 20, count: 8 * 2)
        try ScreenSnapshot.writePNG(words: words, width: 8, height: 2, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerComponent, 16)
    }
}
