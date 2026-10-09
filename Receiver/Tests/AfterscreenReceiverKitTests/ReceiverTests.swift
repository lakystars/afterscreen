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
    func showTiles(_ frame: TileFrame) -> Bool {
        guard let raw = try? frame.decodeAll() else { return false }
        record { tiles.append(raw); log.append("tiles") }
        tileGate?.wait()
        return true
    }
    func setVideoParams(codec: VideoCodec, parameterSets: [Data]) -> Bool { record { log.append("params") }; return true }
    func decodeVideo(avcc: Data) -> Bool { record { videoFrames += 1; log.append("video") }; return true }
    func cursor(x: Float, y: Float, visible: Bool) {}
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
        XCTAssertEqual(try JSONWire.decode(Welcome.self, from: replies[0].payload), welcome)
    }

    func testVersionMismatchSaysBye() throws {
        let replies = expectReply(2) {
            client.send(try! JSONWire.message(.hello, Hello(protocolVersion: 999, name: "MBP", model: "x", osVersion: "27")))
        }
        XCTAssertEqual(replies.map(\.type), [.welcome, .bye])
    }

    func testConfigBeginsStream() {
        let config = StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128),
                                  sourcePoints: PixelSize(width: 128, height: 64), video: nil, linkKind: .loopback)
        client.send(try! JSONWire.message(.config, config))
        waitForDisplay { [display] in display.begun == [config] }
    }

    func testTileFrameReachesDisplay() {
        let g = TileGeometry(width: 256, height: 128)
        let frame = tilePayload(g, runs: [TileRun(row: 0, first: 0, count: 1), TileRun(row: 1, first: 2, count: 2)])
        client.send(try! JSONWire.message(.config, StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128),
                                                                 sourcePoints: PixelSize(width: 128, height: 64), video: nil, linkKind: .loopback)))
        client.send(Message(type: .tileFrame, payload: frame.payload))
        waitForDisplay { [display] in display.tiles.count == 1 }
        XCTAssertEqual(display.tiles.first, frame.raw)
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
                                          sourcePoints: PixelSize(width: 128, height: 64), video: nil, linkKind: .loopback)

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
                                            sourcePoints: PixelSize(width: 128, height: 64),
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
