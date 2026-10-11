import AppKit
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
        XCTAssertEqual(MotionLabel.video(hevc, bitrate: 48_000_000), "HEVC 10-bit 2560×1440 · 48 Mbps", "the encoder's rate now")
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

    func testEachLinkHasASystemSymbol() {
        XCTAssertEqual(LinkLabel.symbol(.thunderbolt), "bolt.fill")
        XCTAssertEqual(LinkLabel.symbol(.usb), "cable.connector")
        XCTAssertEqual(LinkLabel.symbol(.ethernet), "arrow.left.arrow.right")
        XCTAssertEqual(LinkLabel.symbol(.wifi), "wifi")
        XCTAssertNil(LinkLabel.symbol(nil))
        for kind in [LinkKind.thunderbolt, .usb, .ethernet, .wifi, .loopback, .unsupported] {
            let name = LinkLabel.symbol(kind)
            XCTAssertNotNil(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, "\(kind)")
        }
    }

    func testStatusIconKeepsItsSizeAndShowsTheLink() throws {
        let idle = StatusIcon.image(link: nil)
        let bolt = StatusIcon.image(link: .thunderbolt)
        XCTAssertTrue(idle.isTemplate)
        XCTAssertTrue(bolt.isTemplate)
        XCTAssertEqual(idle.size, bolt.size, "the menu bar item does not shift as the link changes")
        XCTAssertEqual(StatusIcon.image(link: .wifi).size, idle.size)
        XCTAssertNotEqual(try pixels(idle), try pixels(bolt))
    }

    func testStatusIconsAreMadeOncePerLink() {
        XCTAssertTrue(StatusIcon.image(link: .wifi) === StatusIcon.image(link: .wifi))
        XCTAssertTrue(StatusIcon.image(link: nil) === StatusIcon.image(link: nil))
        XCTAssertFalse(StatusIcon.image(link: nil) === StatusIcon.image(link: .wifi))
    }

    func testLinkMarksFillTheScreenAlike() {
        let screen = StatusIcon.screen.insetBy(dx: StatusIcon.bezel, dy: StatusIcon.bezel)
        for kind in [LinkKind.thunderbolt, .usb, .ethernet, .wifi] {
            let ink = StatusIcon.markInk(kind)
            XCTAssertTrue(screen.insetBy(dx: 0.5, dy: 0.5).contains(ink), "\(kind) \(ink) clears the bezel")
            XCTAssertTrue(abs(ink.height - StatusIcon.markHeight) < 0.01 || abs(ink.width - StatusIcon.markWidth) < 0.01,
                          "\(kind) is as large as the screen allows: \(ink)")
            XCTAssertEqual(ink.midX, screen.midX, accuracy: 0.5)
            XCTAssertEqual(ink.midY, screen.midY, accuracy: 0.5)
        }
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.tiffRepresentation)
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
