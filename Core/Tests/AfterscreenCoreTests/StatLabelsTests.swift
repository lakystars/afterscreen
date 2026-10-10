import XCTest
@testable import AfterscreenCore

final class StatLabelsTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    func testMotionFormatShowsOnTheTilePathOnly() {
        XCTAssertEqual(MotionLabel.text(path: .tile, lossyTiles: 0), "BC7, sharp")
        XCTAssertEqual(MotionLabel.text(path: .tile, lossyTiles: 12), "BC1 on 12 tiles")
        XCTAssertNil(MotionLabel.text(path: .hybrid, lossyTiles: 3))
    }

    func testVideoLayerNamesCodecDepthSizeAndRate() {
        let hevc = VideoLayer(codec: .hevc, pixels: PixelSize(width: 2560, height: 1440), bitrate: 160_000_000, tenBit: true)
        XCTAssertEqual(MotionLabel.video(hevc), "HEVC 10-bit 2560×1440 · 160 Mbps")
        let h264 = VideoLayer(codec: .h264, pixels: PixelSize(width: 1920, height: 1080), bitrate: 40_000_000, tenBit: false)
        XCTAssertEqual(MotionLabel.video(h264), "H264 1920×1080 · 40 Mbps")
    }

    func testDebandLevelsHaveNames() {
        XCTAssertEqual(Deband.allCases.map(DebandLabel.name), ["Off", "Low", "Medium", "High"])
        L10n.language = .korean
        XCTAssertEqual(DebandLabel.name(.normal), "보통")
    }

    func testLinkGlyphAndName() {
        XCTAssertEqual(LinkLabel.glyph(.thunderbolt), "ϟ")
        XCTAssertEqual(LinkLabel.name(.ethernet), "Ethernet")
        XCTAssertEqual(LinkLabel.name(nil), "—")
    }

    func testJumboFramesAreAdvisedOnWiredLinks() {
        XCTAssertEqual(LinkLabel.mtuAdvice(mtu: 1500, link: .thunderbolt), "9000 recommended")
        XCTAssertNil(LinkLabel.mtuAdvice(mtu: 9000, link: .thunderbolt))
        XCTAssertNil(LinkLabel.mtuAdvice(mtu: 1500, link: .wifi))
        XCTAssertNil(LinkLabel.mtuAdvice(mtu: nil, link: .usb))
    }

    func testLinkScoreBands() {
        XCTAssertEqual(ScoreBand(100), .good)
        XCTAssertEqual(ScoreBand(80), .good)
        XCTAssertEqual(ScoreBand(79), .fair)
        XCTAssertEqual(ScoreBand(50), .fair)
        XCTAssertEqual(ScoreBand(49), .poor)
        XCTAssertEqual(ScoreBand(nil), .good)
    }
}
