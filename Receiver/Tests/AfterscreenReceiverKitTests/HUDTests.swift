import AfterscreenCore
import XCTest
@testable import AfterscreenReceiverKit

final class HUDContentTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    private let tiles = StreamConfig(path: .tile, streamPixels: PixelSize(width: 5120, height: 2880), video: nil, linkKind: .thunderbolt)

    private func telemetry(sender: Bool = true) -> HUDTelemetry {
        var t = HUDTelemetry()
        if sender {
            t.sender = SenderStats(interface: "bridge0", capacityGbps: 12.98, throughputBitsPerSecond: 754e6,
                                   latencyMs: 1, jitterMs: 0, retransmitPercent: 0, cableScore: 97,
                                   captureFPS: 60, sentFPS: 59, droppedPerMinute: 2, dirtyPercent: 11, compressionRatio: 1,
                                   encodeMs: 2.6, lossyTiles: 0, cpuPercent: 13, memoryBytes: 196 << 20, gpuPercent: 16)
            t.throughput.push(700e6)
            t.throughput.push(754e6)
        }
        t.receiver = ReceiverStats(receivedFPS: 60, displayedFPS: 58, uploadMs: 0.4, decompressMs: 0, lateFrames: 0,
                                   cpuPercent: 8, memoryBytes: 70 << 20, gpuPercent: 22)
        t.deband = .normal
        return t
    }

    private func row(_ c: HUDContent, _ label: String) -> HUDContent.Row? {
        c.sections.flatMap(\.rows).first { $0.label == label }
    }

    func testSectionsFollowThePopover() {
        let c = HUDContent.make(peer: "MacBook Pro", config: tiles, telemetry: telemetry())
        XCTAssertEqual(c.title, "MacBook Pro")
        XCTAssertEqual(c.sections.map(\.title), ["Connection", "Picture", "Resources · CPU · RAM · GPU"])
        XCTAssertEqual(row(c, "Link")?.value, "Thunderbolt · bridge0")
        XCTAssertEqual(row(c, "Link")?.link, .thunderbolt, "drawn as the link's symbol")
        XCTAssertEqual(row(c, "Throughput")?.value, "754 Mbps")
        XCTAssertEqual(row(c, "Throughput")?.graph, [700e6, 754e6])
        XCTAssertEqual(row(c, "Measured link speed")?.value, "12.98 Gbps")
        XCTAssertEqual(row(c, "Link quality")?.value, "97 / 100")
        XCTAssertEqual(row(c, "Link quality")?.tone, .good)
        XCTAssertEqual(row(c, "Frames: captured · sent · shown")?.value, "60 · 59 · 58")
        XCTAssertEqual(row(c, "Transfer resolution")?.value, "5120×2880")
        XCTAssertEqual(row(c, "Motion sent as")?.value, "BC7, sharp")
        // Rows named for each Mac
        XCTAssertEqual(row(c, "MacBook Pro")?.value, "13% · 196 MB · 16%")
        XCTAssertEqual(row(c, ComputerName.current)?.value, "8% · 70 MB · 22%")
    }

    func testSmoothingShowsTheLevelOnly() {
        let c = HUDContent.make(peer: nil, config: tiles, telemetry: telemetry())
        XCTAssertEqual(row(c, "Smoothing")?.value, "Medium")
    }

    func testHybridPathNamesTheVideoLayer() {
        let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 2560, height: 1440), bitrate: 160_000_000, tenBit: true)
        let hybrid = StreamConfig(path: .hybrid, streamPixels: PixelSize(width: 4096, height: 2304), video: layer, linkKind: .wifi)
        var t = telemetry()
        t.sender?.videoBitrate = 48_000_000
        let c = HUDContent.make(peer: nil, config: hybrid, telemetry: t)
        XCTAssertEqual(row(c, "Motion sent as")?.value, "HEVC 10-bit · 2560×1440")
        XCTAssertEqual(row(c, "Video target bitrate")?.value, "48 Mbps")
        XCTAssertEqual(row(c, "Link")?.value, "Wi-Fi · bridge0")
        XCTAssertEqual(row(c, "Link")?.link, .wifi)
        let early = HUDContent.make(peer: nil, config: hybrid, telemetry: telemetry(sender: false))
        XCTAssertEqual(row(early, "Video target bitrate")?.value, "160 Mbps", "no stats yet: the layer's")
        t.sender?.videoBitrate = nil
        let failed = HUDContent.make(peer: nil, config: hybrid, telemetry: t)
        XCTAssertEqual(row(failed, "Motion sent as")?.value, "BC7, sharp", "encoder failed: tiles carry motion")
        XCTAssertNil(row(failed, "Video target bitrate"))
    }

    func testWithoutSenderStatsTheReceiverNumbersStillShow() {
        var test = tiles
        test.test = true
        let c = HUDContent.make(peer: nil, config: test, telemetry: telemetry(sender: false))
        XCTAssertEqual(c.title, "Afterscreen")
        XCTAssertEqual(c.status, "Quality test")
        XCTAssertEqual(row(c, "Throughput")?.value, "—")
        XCTAssertEqual(row(c, "Frames: captured · sent · shown")?.value, "— · — · 58")
        XCTAssertEqual(c.summary, "58 fps")
    }

    func testCollapsedSummary() {
        let c = HUDContent.make(peer: nil, config: tiles, telemetry: telemetry())
        XCTAssertEqual(c.status, "Streaming")
        XCTAssertEqual(c.summary, "58 fps · 754 Mbps · 1 ms · quality 97")
    }
}

final class HUDPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let size = CGSize(width: 330, height: 500)

    func testTopCornersClearTheStreamedMenuBar() {
        let frame = HUDPlacement.frame(size: size, corner: .topRight, in: screen)
        XCTAssertEqual(frame, CGRect(x: 2560 - 16 - 330, y: 1440 - HUDPlacement.top - 500, width: 330, height: 500))
        XCTAssertGreaterThanOrEqual(HUDPlacement.top, 48, "a 1.5× scaled 24 pt menu bar plus a margin")
    }

    func testBottomCornersSitAtTheMargin() {
        XCTAssertEqual(HUDPlacement.frame(size: size, corner: .bottomLeft, in: screen).origin, CGPoint(x: 16, y: 16))
    }

    func testATallHUDStaysAboveTheBottomMargin() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertEqual(HUDPlacement.frame(size: size, corner: .topLeft, in: small).minY, 16)
    }

    func testDropSnapsToTheNearestCorner() {
        func at(_ x: CGFloat, _ y: CGFloat) -> ReceiverSettings.HUDCorner {
            HUDPlacement.nearest(to: CGRect(origin: CGPoint(x: x, y: y), size: size), in: screen)
        }
        XCTAssertEqual(at(2000, 900), .topRight)
        XCTAssertEqual(at(100, 900), .topLeft)
        XCTAssertEqual(at(100, 50), .bottomLeft)
        XCTAssertEqual(at(1500, 100), .bottomRight)
    }
}
