import AppKit
import XCTest
@testable import AfterscreenCore

final class StatLabelsTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    func testMotionShowsHowMovingAreasGoOut() {
        let size = PixelSize(width: 3024, height: 1964)
        let tiles = StreamConfig(path: .tile, streamPixels: size, video: nil, linkKind: .thunderbolt)
        XCTAssertEqual(MotionLabel.text(tiles, videoBitrate: nil, lossyTiles: 0), "BC7, sharp")
        XCTAssertEqual(MotionLabel.text(tiles, videoBitrate: nil, lossyTiles: 12), "BC1 on 12 tiles")
        let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 2560, height: 1440), bitrate: 80_000_000)
        let hybrid = StreamConfig(path: .hybrid, streamPixels: size, video: layer, linkKind: .wifi)
        XCTAssertEqual(MotionLabel.text(hybrid, videoBitrate: 40_000_000, lossyTiles: 3), "HEVC · 2560×1440")
        XCTAssertEqual(MotionLabel.target(hybrid, videoBitrate: 40_000_000), "40 Mbps", "the encoder's target now")
        XCTAssertEqual(MotionLabel.text(hybrid, videoBitrate: nil, lossyTiles: 3), "BC1 on 3 tiles", "the encoder failed")
        XCTAssertNil(MotionLabel.target(hybrid, videoBitrate: nil))
        XCTAssertNil(MotionLabel.target(tiles, videoBitrate: nil))
    }

    func testVideoLayerNamesCodecDepthAndSize() {
        let hevc = VideoLayer(codec: .hevc, pixels: PixelSize(width: 2560, height: 1440), bitrate: 160_000_000, tenBit: true)
        XCTAssertEqual(MotionLabel.video(hevc), "HEVC 10-bit · 2560×1440")
        let h264 = VideoLayer(codec: .h264, pixels: PixelSize(width: 1920, height: 1080), bitrate: 40_000_000, tenBit: false)
        XCTAssertEqual(MotionLabel.video(h264), "H264 · 1920×1080")
        L10n.language = .korean
        XCTAssertEqual(MotionLabel.video(hevc), "HEVC 10비트 · 2560×1440")
    }

    func testValuesKeepTheirSourcesPrecision() {
        XCTAssertEqual(StatValue.latency(0.4), "<1 ms")
        XCTAssertEqual(StatValue.latency(9), "9 ms")
        XCTAssertEqual(StatValue.latency(nil), "—")
        XCTAssertEqual(StatValue.capacity(0.2), "200 Mbps", "as throughput beside it")
        XCTAssertEqual(StatValue.capacity(11.5), "11.50 Gbps")
        XCTAssertEqual(StatValue.encode(0), "—", "no frame in the last second")
        XCTAssertEqual(StatValue.encode(4.3), "4.3 ms")
    }

    func testHardwareDecodeListsVideoDecodersOnly() {
        func welcome(hevc: Bool, main10: Bool, h264: Bool) -> Welcome {
            Welcome(protocolVersion: 1, name: "iMac", modelID: "iMac18,3", marketingName: "iMac", osVersion: "13.7.8", gpuNames: [],
                    panelPixels: PixelSize(width: 5120, height: 2880), panelPoints: PixelSize(width: 2560, height: 1440),
                    hevcDecode: hevc, h264Decode: h264, bc7: true, hevcMain10Decode: main10)
        }
        XCTAssertEqual(HardwareDecodeLabel.text(welcome(hevc: true, main10: true, h264: true)), "HEVC ✓ (10-bit ✓) · H.264 ✓")
        XCTAssertEqual(HardwareDecodeLabel.text(welcome(hevc: true, main10: false, h264: true)), "HEVC ✓ (10-bit ✗) · H.264 ✓")
        XCTAssertEqual(HardwareDecodeLabel.text(welcome(hevc: false, main10: false, h264: true)), "HEVC ✗ · H.264 ✓")
        L10n.language = .korean
        XCTAssertEqual(HardwareDecodeLabel.text(welcome(hevc: true, main10: true, h264: true)), "HEVC ✓ (10비트 ✓) · H.264 ✓")
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
        let idle = StatusIcon.image(link: nil, role: .sender)
        let bolt = StatusIcon.image(link: .thunderbolt, role: .sender)
        XCTAssertTrue(idle.isTemplate)
        XCTAssertTrue(bolt.isTemplate)
        XCTAssertEqual(idle.size, bolt.size, "the menu bar item does not shift as the link changes")
        XCTAssertEqual(StatusIcon.image(link: .wifi, role: .sender).size, idle.size)
        XCTAssertNotEqual(try pixels(idle), try pixels(bolt))
    }

    func testStatusIconsAreMadeOncePerLinkAndRole() {
        XCTAssertTrue(StatusIcon.image(link: .wifi, role: .sender) === StatusIcon.image(link: .wifi, role: .sender))
        XCTAssertTrue(StatusIcon.image(link: nil, role: .receiver) === StatusIcon.image(link: nil, role: .receiver))
        XCTAssertFalse(StatusIcon.image(link: nil, role: .sender) === StatusIcon.image(link: .wifi, role: .sender))
        XCTAssertFalse(StatusIcon.image(link: nil, role: .sender) === StatusIcon.image(link: nil, role: .receiver))
    }

    func testTheCornerBadgeTellsTheAppsApart() throws {
        let sender = StatusIcon.image(link: nil, role: .sender)
        let receiver = StatusIcon.image(link: nil, role: .receiver)
        XCTAssertEqual(sender.size, receiver.size)
        XCTAssertNotEqual(try pixels(sender), try pixels(receiver), "arrow out and arrow in")
        // Top bezel: whole, then the gap, then the disc
        let c = StatusIcon.badgeCentre, r = StatusIcon.badgeRadius
        let bezelY = StatusIcon.screen.maxY
        let gapX = c.x - ((r + StatusIcon.badgeGap / 2) * (r + StatusIcon.badgeGap / 2) - (bezelY - c.y) * (bezelY - c.y)).squareRoot()
        for image in [sender, receiver] {
            XCTAssertGreaterThan(try alpha(image, at: NSPoint(x: 5, y: bezelY)), 0.9)
            XCTAssertLessThan(try alpha(image, at: NSPoint(x: gapX, y: bezelY)), 0.1)
            XCTAssertGreaterThan(try alpha(image, at: NSPoint(x: c.x, y: c.y + r - 0.5)), 0.9)
        }
        // Arrowhead: top right on the sender, bottom left on the receiver
        let head = NSPoint(x: c.x + 0.8, y: c.y + 1.75), tail = NSPoint(x: c.x - 0.8, y: c.y - 1.75)
        XCTAssertLessThan(try alpha(sender, at: head), 0.1)
        XCTAssertGreaterThan(try alpha(sender, at: tail), 0.9)
        XCTAssertLessThan(try alpha(receiver, at: tail), 0.1)
        XCTAssertGreaterThan(try alpha(receiver, at: head), 0.9)
        // Disc flush with the bezel's outer corner
        XCTAssertEqual(c.x + r, StatusIcon.screen.maxX + StatusIcon.bezel, accuracy: 0.01)
        XCTAssertEqual(c.y + r, StatusIcon.screen.maxY + StatusIcon.bezel, accuracy: 0.01)
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

    /// Alpha at a point in points, drawn at 4x
    private func alpha(_ image: NSImage, at point: NSPoint) throws -> CGFloat {
        let s: CGFloat = 4, w = Int(image.size.width * s), h = Int(image.size.height * s)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows run top down
        return try XCTUnwrap(rep.colorAt(x: Int(point.x * s), y: Int((image.size.height - point.y) * s))).alphaComponent
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
