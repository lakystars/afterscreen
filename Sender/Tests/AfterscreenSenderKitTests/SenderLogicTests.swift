import AppKit
import CoreGraphics
import AfterscreenCore
import ScreenCaptureKit
import XCTest
@testable import AfterscreenSenderKit

final class ModePickerTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double = 60) -> ModeInfo {
        ModeInfo(width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: hz)
    }

    private let fiveK = PixelSize(width: 2560, height: 1440)

    func testPrefersTheHiDPIModeOverSamePointsLowRes() {
        let modes = [mode(2560, 1440, 2560, 1440), mode(2560, 1440, 5120, 2880), mode(1920, 1080, 3840, 2160)]
        XCTAssertEqual(VirtualDisplay.pickMode(modes, points: fiveK, hiDPI: true), 1)
        XCTAssertEqual(VirtualDisplay.pickMode(modes, points: fiveK, hiDPI: false), 0)
    }

    func testScaledHiDPIModeHasDoubleBacking() {
        let modes = [mode(2880, 1620, 2880, 1620), mode(2880, 1620, 5760, 3240), mode(2560, 1440, 5120, 2880)]
        XCTAssertEqual(VirtualDisplay.pickMode(modes, points: PixelSize(width: 2880, height: 1620), hiDPI: true), 1)
    }

    func testPrefersHigherRefreshAmongExactMatches() {
        let modes = [mode(2560, 1440, 5120, 2880, 30), mode(2560, 1440, 5120, 2880, 60)]
        XCTAssertEqual(VirtualDisplay.pickMode(modes, points: fiveK, hiDPI: true), 1)
    }

    func testFallsBackToLargestPixelsAtRequestedPoints() {
        let modes = [mode(2560, 1440, 2560, 1440), mode(1280, 720, 2560, 1440), mode(2560, 1440, 4096, 2304)]
        XCTAssertEqual(VirtualDisplay.pickMode(modes, points: fiveK, hiDPI: true), 2)
        XCTAssertNil(VirtualDisplay.pickMode([], points: fiveK, hiDPI: true))
    }
}

final class PopoverLabelTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    func testAPinnedLinkThatStoppedAnsweringStaysListedAsUnreachable() {
        let pinnedGone = LinkMenu.choices(available: [.thunderbolt, .wifi], pinned: .usb)
        XCTAssertEqual(pinnedGone.map(\.kind), [.thunderbolt, .wifi, .usb])
        XCTAssertEqual(pinnedGone.map(\.reachable), [true, true, false])
        XCTAssertEqual(LinkMenu.choices(available: [.thunderbolt, .wifi], pinned: .wifi).map(\.kind), [.thunderbolt, .wifi])
        XCTAssertTrue(LinkMenu.choices(available: [], pinned: nil).isEmpty)
    }

    func testAutomaticLinkMovesOnlyToAFasterOne() {
        XCTAssertEqual(RoutePlanner.upgrade(from: .wifi, available: [.ethernet, .wifi]), .ethernet, "a cable plugged in")
        XCTAssertEqual(RoutePlanner.upgrade(from: .ethernet, available: [.thunderbolt, .ethernet, .wifi]), .thunderbolt)
        XCTAssertNil(RoutePlanner.upgrade(from: .ethernet, available: [.ethernet, .wifi]), "already the fastest")
        XCTAssertNil(RoutePlanner.upgrade(from: .thunderbolt, available: [.usb, .wifi]), "never down")
        XCTAssertNil(RoutePlanner.upgrade(from: .loopback, available: [.wifi]))
        XCTAssertNil(RoutePlanner.upgrade(from: nil, available: [.ethernet]))
        XCTAssertEqual(AppModel.fasterLinkOutcome(wanted: .ethernet, got: .ethernet), "Switched to the faster Ethernet")
        XCTAssertEqual(AppModel.fasterLinkOutcome(wanted: .ethernet, got: .wifi), "Ethernet did not connect; on Wi-Fi instead")
    }

    func testWireStatsCarryThePopoverNumbers() {
        var s = SenderSnapshot()
        s.interface = "bridge0"
        s.capacityGbps = 12.4
        s.throughputBitsPerSecond = 754e6
        s.latencyMs = 1
        s.jitterMs = 0.2
        s.retransmitPercent = 0.5
        s.cableScore = 97
        s.captureFPS = 60
        s.sentFPS = 59
        s.droppedPerMinute = 3
        s.dirtyPercent = 11
        s.compressionRatio = 1.4
        s.encodeMs = 2.6
        s.lossyTiles = 4
        s.cpuPercent = 13
        s.memoryBytes = 196 << 20
        s.gpuPercent = 16
        XCTAssertEqual(s.wireStats, SenderStats(interface: "bridge0", capacityGbps: 12.4, throughputBitsPerSecond: 754e6,
                                                latencyMs: 1, jitterMs: 0.2, retransmitPercent: 0.5, cableScore: 97,
                                                captureFPS: 60, sentFPS: 59, droppedPerMinute: 3, dirtyPercent: 11,
                                                compressionRatio: 1.4, encodeMs: 2.6, lossyTiles: 4, cpuPercent: 13,
                                                memoryBytes: 196 << 20, gpuPercent: 16))
    }
}

final class CaptureConfigurationTests: XCTestCase {
    func testCapturesEightBitSRGBWithoutExtendedRange() {
        let c = Capture.configuration(size: PixelSize(width: 5120, height: 2880))
        XCTAssertEqual(c.width, 5120)
        XCTAssertEqual(c.height, 2880)
        XCTAssertEqual(c.pixelFormat, kCVPixelFormatType_32BGRA, "the virtual display composites in 8-bit")
        if #available(macOS 15.0, *) { XCTAssertEqual(c.captureDynamicRange, .SDR) }
        XCTAssertEqual(c.colorSpaceName, CGColorSpace.sRGB)
        XCTAssertFalse(c.showsCursor)
    }
}

final class CursorNormalizeTests: XCTestCase {
    let bounds = CGRect(x: 1800, y: -592, width: 2560, height: 1440)

    func testInsideIsNormalizedTopLeft() {
        let r = CursorTracker.normalize(point: CGPoint(x: 1800 + 640, y: -592 + 360), displayBounds: bounds)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(r.y, 0.25, accuracy: 1e-6)
        XCTAssertTrue(r.visible)
    }

    func testAutoConnectNeverPutsACodeOnAnotherIMac() {
        XCTAssertTrue(AppModel.connectsWithoutCode(paired: true, route: .wifi))
        XCTAssertTrue(AppModel.connectsWithoutCode(paired: false, route: .thunderbolt), "a cable needs no code")
        XCTAssertTrue(AppModel.connectsWithoutCode(paired: false, route: .usb))
        XCTAssertFalse(AppModel.connectsWithoutCode(paired: false, route: .wifi))
        XCTAssertFalse(AppModel.connectsWithoutCode(paired: false, route: .ethernet))
        XCTAssertFalse(AppModel.connectsWithoutCode(paired: false, route: nil), "links not known yet: wait")
    }

    func testAKnownReceiverMustProveItself() {
        XCTAssertTrue(SenderSession.expectsProof(pairedTarget: true, pairedReceiver: false, pairedName: false))
        XCTAssertTrue(SenderSession.expectsProof(pairedTarget: false, pairedReceiver: true, pairedName: false))
        XCTAssertTrue(SenderSession.expectsProof(pairedTarget: false, pairedReceiver: false, pairedName: true),
                      "a look-alike under a paired name with a new ID")
        XCTAssertFalse(SenderSession.expectsProof(pairedTarget: false, pairedReceiver: false, pairedName: false), "an open receiver")
    }

    func testAutoConnectJudgesTheLinkThatAnswers() {
        XCTAssertEqual(AppModel.route(pinned: .thunderbolt, answering: [.thunderbolt, .wifi]), .thunderbolt)
        XCTAssertEqual(AppModel.route(pinned: .thunderbolt, answering: [.wifi]), .wifi, "pinned cable unplugged: Wi-Fi carries it")
        XCTAssertEqual(AppModel.route(pinned: nil, answering: [.usb, .wifi]), .usb)
        XCTAssertNil(AppModel.route(pinned: .wifi, answering: nil))
    }

    func testBrightnessFollowsRealChangesNotSensorNoise() {
        XCTAssertTrue(SenderSession.brightnessChanged(0.5, from: nil), "first reading goes out")
        XCTAssertFalse(SenderSession.brightnessChanged(0.502, from: 0.5))
        XCTAssertTrue(SenderSession.brightnessChanged(0.45, from: 0.5))
        XCTAssertTrue(SenderSession.brightnessChanged(0, from: 0.0625), "down to the lowest step")
    }

    func testOutsideIsHidden() {
        XCTAssertFalse(CursorTracker.normalize(point: CGPoint(x: 100, y: 100), displayBounds: bounds).visible)
        XCTAssertFalse(CursorTracker.normalize(point: CGPoint(x: 1800 + 2560, y: 0), displayBounds: bounds).visible)
        XCTAssertTrue(CursorTracker.normalize(point: CGPoint(x: 1800, y: -592), displayBounds: bounds).visible)
    }
}

final class PathPolicyTests: XCTestCase {
    private func welcome(panel: PixelSize, hevc: Bool = true, main10: Bool = false) -> Welcome {
        Welcome(protocolVersion: 1, name: "iMac", modelID: "iMac18,3", marketingName: "iMac", osVersion: "13.7", gpuNames: [],
                panelPixels: panel, panelPoints: panel.width >= 3000 ? PixelSize(width: panel.width / 2, height: panel.height / 2) : panel,
                hevcDecode: hevc, h264Decode: true, bc7: true, hevcMain10Decode: main10)
    }

    private let fiveK = PixelSize(width: 5120, height: 2880)

    func testARelinkKeepsSizeAndRateAndFollowsTheNewLink() throws {
        let w = welcome(panel: fiveK)
        let wifi = try XCTUnwrap(PathPolicy.choose(link: .wifi, capacityGbps: 0.2, welcome: w, resolution: .reduced))
        let ethernet = PathPolicy.relink(wifi, link: .ethernet, capacityGbps: 0.95, welcome: w)
        XCTAssertEqual(ethernet.streamPixels, wifi.streamPixels, "the desktop keeps its size")
        XCTAssertEqual(ethernet.frameRate, wifi.frameRate)
        XCTAssertEqual(ethernet.linkKind, .ethernet)
        XCTAssertGreaterThan(try XCTUnwrap(ethernet.video?.bitrate), try XCTUnwrap(wifi.video?.bitrate))
        let thunderbolt = PathPolicy.relink(wifi, link: .thunderbolt, capacityGbps: 12, welcome: w)
        XCTAssertEqual(thunderbolt.path, .tile)
        XCTAssertEqual(thunderbolt.streamPixels, wifi.streamPixels)
        XCTAssertEqual(PathPolicy.relink(thunderbolt, link: .wifi, capacityGbps: 0.2, welcome: w).path, .hybrid, "and back")
    }

    func testThunderboltWithCapacityUsesTilesAtPanelPixels() {
        let c = PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK))
        XCTAssertEqual(c?.path, .tile)
        XCTAssertEqual(c?.streamPixels, fiveK)
        XCTAssertNil(c?.video)
        XCTAssertEqual(PathPolicy.choose(link: .ethernet, capacityGbps: 9.4, welcome: welcome(panel: fiveK))?.path, .tile)
    }

    func testMirrorStreamsTheSourcePixelsTheReceiverLetterboxes() {
        let macBook = PixelSize(width: 3024, height: 1964)
        let c = PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK), source: macBook)
        XCTAssertEqual(c?.streamPixels, macBook, "smaller than the panel: no upscale before sending")
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK),
                                         source: PixelSize(width: 6016, height: 3384))?.streamPixels, fiveK, "larger: fit to the panel")
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK),
                                         source: PixelSize(width: 3456, height: 2234))?.streamPixels, PixelSize(width: 3456, height: 2232),
                       "block-aligned")
        let wifi = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK), resolution: .reduced, source: macBook)
        XCTAssertEqual(wifi?.streamPixels, macBook, "within four fifths of the panel: still areas 1:1 when reduced")
        XCTAssertEqual(wifi?.video?.pixels, PixelSize(width: 2416, height: 1568), "moving areas at four fifths, as extend sends")
        XCTAssertEqual(PathPolicy.choose(link: .ethernet, capacityGbps: 0.9, welcome: welcome(panel: fiveK), resolution: .auto,
                                         source: macBook)?.video?.pixels, macBook, "unreduced link: video at the stream's size")
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.3, welcome: welcome(panel: fiveK), resolution: .auto,
                                         source: macBook)?.video?.pixels, macBook, "measured against the MacBook's pixels, not 5K's")
        let extend = PathPolicy.choose(link: .wifi, capacityGbps: 0.2, welcome: welcome(panel: fiveK), resolution: .auto)
        let large = PathPolicy.choose(link: .wifi, capacityGbps: 0.2, welcome: welcome(panel: fiveK), resolution: .auto, source: fiveK)
        XCTAssertEqual(large?.streamPixels, extend?.streamPixels)
        XCTAssertEqual(large?.video?.pixels, extend?.video?.pixels, "a panel-sized source: video as in extend, not shrunk twice")
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.17, welcome: welcome(panel: fiveK), resolution: .auto,
                                         source: PixelSize(width: 2048, height: 1330))?.streamPixels, PixelSize(width: 2048, height: 1328))
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.2, welcome: welcome(panel: fiveK), resolution: .auto,
                                         source: PixelSize(width: 4096, height: 2660))?.streamPixels, PixelSize(width: 3544, height: 2304),
                       "larger than four fifths: fit within 4096 × 2304")
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK), resolution: .reduced,
                                         source: macBook)?.streamPixels, macBook, "four fifths caps pixels; it never shrinks a smaller source")
    }

    func testMirrorSourcePixelsFollowRotation() {
        XCTAssertEqual(MirrorSource.pixels(bounds: CGSize(width: 1512, height: 982), scale: 2), PixelSize(width: 3024, height: 1964))
        XCTAssertEqual(MirrorSource.pixels(bounds: CGSize(width: 982, height: 1512), scale: 2), PixelSize(width: 1964, height: 3024))
        XCTAssertEqual(MirrorSource.pixels(bounds: CGSize(width: 2048, height: 1330), scale: 1), PixelSize(width: 2048, height: 1330))
    }

    func testTheCaptureRegionHasTheStreamsShape() {
        let lowDPI = MirrorSource(displayID: 1, pixels: PixelSize(width: 2048, height: 1330), scale: 1)
        XCTAssertEqual(lowDPI.region(for: PixelSize(width: 2048, height: 1328)), CGRect(x: 0, y: 0, width: 2048, height: 1328),
                       "alignment only: 1:1, last rows dropped instead of resampling")
        let retina = MirrorSource(displayID: 1, pixels: PixelSize(width: 3456, height: 2234), scale: 2)
        XCTAssertEqual(retina.region(for: PixelSize(width: 3456, height: 2232)), CGRect(x: 0, y: 0, width: 1728, height: 1116))
        for (source, stream) in [(PixelSize(width: 3024, height: 1964), PixelSize(width: 2416, height: 1568)),
                                 (PixelSize(width: 1964, height: 3024), PixelSize(width: 1868, height: 2880)),
                                 (PixelSize(width: 6016, height: 3384), PixelSize(width: 5120, height: 2880))] {
            let r = MirrorSource(displayID: 1, pixels: source, scale: 2).region(for: stream)
            XCTAssertEqual(r.width / r.height, CGFloat(stream.width) / CGFloat(stream.height), accuracy: 1e-9, "scaled: no bars inside the stream")
            XCTAssertLessThanOrEqual(r.width * 2, CGFloat(source.width) + 1e-9)
            XCTAssertLessThanOrEqual(r.height * 2, CGFloat(source.height) + 1e-9)
        }
    }

    func testTheIMacFitMirrorsTheMainDisplayNeverTheVirtualOne() {
        let builtIn: (CGDirectDisplayID) -> Bool = { $0 == 1 }
        let none: (CGDirectDisplayID) -> CGDirectDisplayID = { _ in 0 }
        func source(_ online: [CGDirectDisplayID], _ active: [CGDirectDisplayID], main: CGDirectDisplayID,
                    mirrorOf: @escaping (CGDirectDisplayID) -> CGDirectDisplayID = none) -> CGDirectDisplayID? {
            DisplayMirror.source(online: online, active: active, main: main, builtIn: builtIn, mirrorOf: mirrorOf, excluding: 9)
        }
        XCTAssertEqual(source([1, 2, 9], [1, 2, 9], main: 2), 2, "the main display")
        XCTAssertEqual(source([1, 2, 9], [1, 2, 9], main: 9), 1, "virtual display made main earlier: the built-in")
        XCTAssertEqual(source([3, 9], [3, 9], main: 9), 3)
        XCTAssertNil(source([9], [9], main: 9))
        XCTAssertEqual(source([1, 9], [9], main: 9, mirrorOf: { $0 == 1 ? 9 : 0 }), 1,
                       "macOS restored the mirror set: the built-in is no longer active, yet it is the source")
    }

    func testThePointerMapsOntoTheCroppedArea() {
        let display = CGRect(x: -2048, y: 0, width: 2048, height: 1330)
        let area = CursorTracker.area(display: display, crop: CGRect(x: 0, y: 0, width: 2048, height: 1328))
        XCTAssertEqual(CursorTracker.normalize(point: CGPoint(x: -1024, y: 1327.9), displayBounds: area).y, 1327.9 / 1328, accuracy: 1e-6)
        XCTAssertFalse(CursorTracker.normalize(point: CGPoint(x: -1024, y: 1329), displayBounds: area).visible, "the dropped rows are off the stream")
        XCTAssertEqual(CursorTracker.area(display: display, crop: nil), display)
    }

    func testSlowLinksUseHybridAtPanelPixelsWithA4KVideoLayer() {
        for (link, gbps) in [(LinkKind.usb, 1.0), (.ethernet, 0.94), (.wifi, 0.6), (.wifi, 5)] {
            let c = PathPolicy.choose(link: link, capacityGbps: gbps, welcome: welcome(panel: fiveK))
            XCTAssertEqual(c?.path, .hybrid, "\(link) \(gbps)")
            XCTAssertEqual(c?.streamPixels, fiveK)
            XCTAssertEqual(c?.video?.codec, .hevc)
            XCTAssertEqual(c?.video?.pixels, PixelSize(width: 3840, height: 2160))
        }
    }

    func testSlowerLinksGetASmallerVideoLayer() {
        // 0.15 bit per pixel at 60 fps: 4K from 75 Mbps, 1440p from 33 Mbps
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.14, welcome: welcome(panel: fiveK))?.video?.pixels,
                       PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.05, welcome: welcome(panel: fiveK))?.video?.pixels,
                       PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.19, welcome: welcome(panel: fiveK))?.video?.pixels,
                       PixelSize(width: 3840, height: 2160))
    }

    func testVideoLayerIsTenBitWhenTheReceiverDecodesMain10() {
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK, main10: true))?.video?.tenBit, true)
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK))?.video?.tenBit, false)
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK, hevc: false, main10: true))?.video?.tenBit,
                       false, "H.264 stays 8-bit")
    }

    func testHybridWithoutHEVCUsesH264At1440p() {
        // 4K60 H.264 needs level 5.2, past the HEVC-less (2014–2015) iMacs' decoders
        let c = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK, hevc: false))
        XCTAssertEqual(c?.video?.codec, .h264)
        XCTAssertEqual(c?.video?.pixels, PixelSize(width: 2560, height: 1440))
    }

    func testVideoLayerKeeps1440pPanelNative() {
        let c = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: PixelSize(width: 2560, height: 1440), hevc: false))
        XCTAssertEqual(c?.video?.pixels, PixelSize(width: 2560, height: 1440))
    }

    func testReceiverWithoutVideoDecodeStaysOnTiles() {
        var w = welcome(panel: fiveK, hevc: false)
        w.h264Decode = false
        let c = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: w)
        XCTAssertEqual(c?.path, .tile)
        XCTAssertNil(c?.video)
    }

    func testQualityTestStagesKeepThePathAndFitTheVideoLayer() throws {
        let c = try XCTUnwrap(PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: welcome(panel: fiveK)))
        let small = PathPolicy.stage(c, size: PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(small.streamPixels, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(small.video?.pixels, PixelSize(width: 1920, height: 1080))
        XCTAssertTrue(small.test)
        XCTAssertEqual(PathPolicy.stage(c, size: fiveK).video?.pixels, PixelSize(width: 3840, height: 2160))
        XCTAssertFalse(c.test)
    }

    func testSettledTilesPerFrameFillHalfAFrameIntervalAtTwoToOne() {
        XCTAssertEqual(PathPolicy.settleTiles(capacityGbps: 0.3, tileBytes: 4096, fps: 60), 152)
        XCTAssertEqual(PathPolicy.settleTiles(capacityGbps: nil, tileBytes: 4096, fps: 60), 16)
    }

    func testAutomaticResolutionFollowsTheMeasuredRate() {
        let retina4K = PixelSize(width: 4096, height: 2304)
        XCTAssertEqual(PathPolicy.fullScreenGbps(fiveK), 0.47, accuracy: 0.01)
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 0.2, resolution: .auto), retina4K, "home Wi-Fi")
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 0.94, resolution: .auto), fiveK, "gigabit Ethernet")
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 0.6, resolution: .auto), fiveK, "fast Wi-Fi")
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 0.09, resolution: .auto), retina4K, "100 Mbps Ethernet")
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: nil, resolution: .auto), retina4K, "unmeasured")
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 10, resolution: .reduced), retina4K)
        XCTAssertEqual(PathPolicy.streamPixels(panel: fiveK, capacityGbps: 0.07, resolution: .panel), fiveK)
        XCTAssertEqual(PathPolicy.streamPixels(panel: retina4K, capacityGbps: 0.2, resolution: .auto), PixelSize(width: 3276, height: 1840),
                       "a 4K iMac: whole blocks of 4")
        XCTAssertEqual(PathPolicy.streamPixels(panel: retina4K, capacityGbps: 0.35, resolution: .auto), retina4K, "fewer pixels need less")
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.07, welcome: welcome(panel: fiveK), resolution: .auto)?.streamPixels, retina4K)
        XCTAssertEqual(PathPolicy.choose(link: .wifi, capacityGbps: 0.07, welcome: welcome(panel: fiveK))?.streamPixels, fiveK, "panel unless asked")
    }

    func testAutomaticHoldsItsLastPickNearTheLine() {
        func pick(_ gbps: Double, _ previous: StreamResolution?) -> StreamResolution {
            PathPolicy.resolve(.auto, panel: fiveK, source: nil, capacityGbps: gbps, previous: previous)
        }
        XCTAssertEqual(pick(0.5, nil), .panel)
        XCTAssertEqual(pick(0.5, .reduced), .reduced, "under 120% of the line: stays reduced")
        XCTAssertEqual(pick(0.6, .reduced), .panel)
        XCTAssertEqual(pick(0.42, .panel), .panel, "within 20% under the line: stays at the panel")
        XCTAssertEqual(pick(0.38, .panel), .reduced)
        XCTAssertEqual(PathPolicy.resolve(.panel, panel: fiveK, source: nil, capacityGbps: 0.01, previous: .reduced), .panel)
        XCTAssertEqual(PathPolicy.resolve(.reduced, panel: fiveK, source: nil, capacityGbps: 10, previous: .panel), .reduced)
    }

    func testAReducedStreamDrawsTheDesktopAtExactlyItsPixels() {
        // Each iMac's own panel: the desktop looks half the stream wide, so the 2× backing is the stream
        let cases: [(panel: PixelSize, stream: PixelSize, looks: PixelSize)] = [
            (fiveK, PixelSize(width: 4096, height: 2304), PixelSize(width: 2048, height: 1152)),           // 27" 5K
            (PixelSize(width: 4480, height: 2520), PixelSize(width: 3584, height: 2016), PixelSize(width: 1792, height: 1008)), // 24"
            (PixelSize(width: 4096, height: 2304), PixelSize(width: 3276, height: 1840), PixelSize(width: 1638, height: 920)),  // 21.5" 4K
        ]
        for c in cases {
            let w = welcome(panel: c.panel)
            let stream = PathPolicy.streamPixels(panel: c.panel, capacityGbps: 0.1, resolution: .auto)
            XCTAssertEqual(stream, c.stream)
            let modes = PathPolicy.displayModes(welcome: w, stream: stream, size: .standard)
            XCTAssertEqual(modes.initial, c.looks, "\(c.panel)")
            XCTAssertTrue(modes.all.contains(c.looks))
            XCTAssertEqual(Set(modes.all.map { "\($0)" }).count, modes.all.count, "no duplicates")
        }
        // Non-Retina panel: no 2× backing, so the desktop is the stream itself
        let flat = welcome(panel: PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(PathPolicy.displayModes(welcome: flat, stream: PixelSize(width: 2048, height: 1152), size: .standard).initial,
                       PixelSize(width: 2048, height: 1152))
        // Panel resolution: the size chosen in the settings
        let w = welcome(panel: fiveK)
        XCTAssertEqual(PathPolicy.displayModes(welcome: w, stream: fiveK, size: .more).initial, DisplaySize.more.points(for: w.panelPoints))
    }

    func testTileThresholdScalesWithPixelsAndRate() {
        XCTAssertEqual(PathPolicy.tileCapacityGbps(fiveK, fps: 60), 2.48, accuracy: 0.01, "5K at 60: the measured 2.5 Gbps")
        XCTAssertEqual(PathPolicy.tileCapacityGbps(PixelSize(width: 1920, height: 1080), fps: 60), 0.35, accuracy: 0.01)
        XCTAssertEqual(PathPolicy.tileCapacityGbps(fiveK, fps: 120), 4.95, accuracy: 0.01)
        let fullHD = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(PathPolicy.choose(link: .ethernet, capacityGbps: 0.9, welcome: welcome(panel: fullHD))?.path, .tile,
                       "gigabit carries 1080p as lossless tiles")
    }

    func testEncoderSpeedCapsTheVideoLayer() {
        let w = welcome(panel: fiveK)
        let free = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: w)
        let capped = PathPolicy.choose(link: .wifi, capacityGbps: 0.6, welcome: w, largestVideo: PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(free?.video?.pixels, PixelSize(width: 3840, height: 2160))
        XCTAssertEqual(capped?.video?.pixels, PixelSize(width: 2560, height: 1440), "a slower encoder takes the next size")
    }

    func testBC7MotionFillsHalfTheLinkAtSixtyFramesPerSecond() {
        XCTAssertEqual(PathPolicy.bc7MotionTiles(capacityGbps: 10, tileBytes: 4096, fps: 60), 2543)
        XCTAssertEqual(PathPolicy.bc7MotionTiles(capacityGbps: 3.8, tileBytes: 4096, fps: 60), 966)
        XCTAssertEqual(PathPolicy.bc7MotionTiles(capacityGbps: nil, tileBytes: 4096, fps: 60), 0)
    }

    func testVideoBitrateIsFortyPercentOfCapacityWithinLimits() {
        XCTAssertEqual(PathPolicy.bitrate(capacityGbps: 0.3), 120_000_000)
        XCTAssertEqual(PathPolicy.bitrate(capacityGbps: 0.94), 200_000_000)
        XCTAssertEqual(PathPolicy.bitrate(capacityGbps: 0.02), 20_000_000)
        XCTAssertEqual(PathPolicy.bitrate(capacityGbps: nil), 20_000_000)
    }

    func testUnsupportedIsRefusedAndLoopbackAllowed() {
        XCTAssertNil(PathPolicy.choose(link: .unsupported, capacityGbps: 10, welcome: welcome(panel: fiveK)))
        XCTAssertEqual(PathPolicy.choose(link: .loopback, capacityGbps: 40, welcome: welcome(panel: fiveK))?.path, .tile)
    }

    func testImplausiblePanelIsRefused() {
        for panel in [PixelSize(width: -5120, height: 2880), PixelSize(width: 0, height: 0), PixelSize(width: 70000, height: 2880)] {
            XCTAssertNil(PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: panel)), "\(panel)")
        }
        var w = welcome(panel: fiveK)
        w.panelPoints = PixelSize(width: -1, height: 1440)
        XCTAssertNil(PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: w))
    }

    func testOddPanelHeightAlignsToBlocks() {
        let c = PathPolicy.choose(link: .loopback, capacityGbps: 40, welcome: welcome(panel: PixelSize(width: 3600, height: 2338)))
        XCTAssertEqual(c?.streamPixels, PixelSize(width: 3600, height: 2336))
    }
}

final class FrameGateTests: XCTestCase {
    func testFrameArrivingTooSoonIsSentLaterNotLost() {
        var gate = FrameGate<String>(interval: 0.015)
        gate.offer("a")
        XCTAssertEqual(gate.take(now: 0, busy: false), "a")
        gate.offer("b")
        XCTAssertNil(gate.take(now: 0.005, busy: false))
        XCTAssertEqual(gate.take(now: 0.02, busy: false), "b")
        XCTAssertNil(gate.take(now: 0.04, busy: false))
    }

    func testBusyLinkKeepsOnlyTheNewestFrame() {
        var gate = FrameGate<String>(interval: 0.015)
        XCTAssertFalse(gate.offer("a"))
        XCTAssertNil(gate.take(now: 1, busy: true))
        XCTAssertTrue(gate.offer("b"))
        XCTAssertEqual(gate.take(now: 1.001, busy: false), "b")
    }
}

final class FrameGateDelayTests: XCTestCase {
    func testDelayIsTimeUntilTheGateOpens() {
        var gate = FrameGate<Int>(interval: 0.016)
        XCTAssertEqual(gate.delay(now: 5), 0)
        gate.offer(1)
        _ = gate.take(now: 10, busy: false)
        XCTAssertEqual(gate.delay(now: 10.004), 0.012, accuracy: 1e-9)
        XCTAssertEqual(gate.delay(now: 10.020), 0)
    }
}

final class CursorPollingTests: XCTestCase {
    func testSlowsDownWhenStillAndSpeedsUpOnMovement() {
        var rate = CursorPollRate()
        XCTAssertEqual(rate.interval, CursorPollRate.moving)
        for _ in 0..<(CursorPollRate.stillPolls - 1) { rate.observe(moved: false) }
        XCTAssertEqual(rate.interval, CursorPollRate.moving)
        rate.observe(moved: false)
        XCTAssertEqual(rate.interval, CursorPollRate.still)
        rate.observe(moved: true)
        XCTAssertEqual(rate.interval, CursorPollRate.moving)
    }

    /// 16×16 pt cursor with 1x and 2x bitmaps filled with `value`
    private func cursor(_ value: UInt8, hot: NSPoint = .zero) -> NSCursor {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for scale in [1, 2] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            memset(rep.bitmapData!, Int32(value), rep.bytesPerRow * rep.pixelsHigh)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return NSCursor(image: image, hotSpot: hot)
    }

    func testCursorSeedIsReadable() {
        XCTAssertNotNil(CursorTracker.seed?())
    }

    func testFingerprintTellsCursorsApart() {
        XCTAssertEqual(CursorTracker.fingerprint(cursor(10)), CursorTracker.fingerprint(cursor(10)))
        XCTAssertNotEqual(CursorTracker.fingerprint(cursor(10)), CursorTracker.fingerprint(cursor(11)))
        XCTAssertNotEqual(CursorTracker.fingerprint(cursor(10)), CursorTracker.fingerprint(cursor(10, hot: NSPoint(x: 3, y: 3))))
        XCTAssertEqual(CursorTracker.bitmap(cursor(10))?.pixelsWide, 32)
    }
}

final class DirtyMergeTests: XCTestCase {
    func testReplacedFrameKeepsTheDroppedFramesRegions() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10), b = CGRect(x: 50, y: 50, width: 5, height: 5)
        XCTAssertEqual(CapturedFrame.merge([a], into: [b]), [b, a])
        XCTAssertNil(CapturedFrame.merge(nil, into: [b]))
        XCTAssertNil(CapturedFrame.merge([a], into: nil))
    }
}

final class DirtyRectScalingTests: XCTestCase {
    private let r = CGRect(x: 800, y: 842, width: 640, height: 158)

    func testNativeOutputKeepsDisplayPixels() {
        let content = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(Capture.scaled([r], content: content, scale: 2, outputWidth: 5120), [r])
    }

    func testScaledOutputAndContentOffset() {
        let half = Capture.scaled([r], content: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2, outputWidth: 2560)
        XCTAssertEqual(half, [CGRect(x: 400, y: 421, width: 320, height: 79)])
        let offset = Capture.scaled([r], content: CGRect(x: 100, y: 0, width: 2360, height: 1440), scale: 2, outputWidth: 4720)
        XCTAssertEqual(offset, [CGRect(x: 600, y: 842, width: 640, height: 158)])
    }

    func testUnusableScaleMeansUnknown() {
        XCTAssertNil(Capture.scaled([r], content: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 0, outputWidth: 5120))
        XCTAssertNil(Capture.scaled([r], content: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: .nan, outputWidth: 5120))
    }

    func testTooManyMergedRegionsMeanUnknown() {
        let many = [CGRect](repeating: r, count: 200)
        XCTAssertNil(CapturedFrame.merge(many, into: many))
    }
}

final class CursorMoveTests: XCTestCase {
    func testMovementOutsideTheDisplayIsNotAMove() {
        XCTAssertFalse(CursorTracker.isMove(from: (0.1, 0.1, false), to: (0.9, 0.2, false)))
        XCTAssertTrue(CursorTracker.isMove(from: (0.1, 0.1, false), to: (0.2, 0.2, true)))
        XCTAssertTrue(CursorTracker.isMove(from: (0.1, 0.1, true), to: (0.2, 0.2, true)))
        XCTAssertFalse(CursorTracker.isMove(from: (0.1, 0.1, true), to: (0.1, 0.1, true)))
    }
}

final class USBFallbackAdviceTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    func testUSBLinkSuggestsReplugForThunderbolt() {
        XCTAssertEqual(LinkMetrics.usbFallbackAdvice(link: .usb),
                       "Connected as USB, not Thunderbolt. With a Thunderbolt cable, replug both ends; if it stays USB, sleep or restart either Mac.")
        XCTAssertNil(LinkMetrics.usbFallbackAdvice(link: .thunderbolt))
        XCTAssertNil(LinkMetrics.usbFallbackAdvice(link: .ethernet))
        XCTAssertNil(LinkMetrics.usbFallbackAdvice(link: nil))
    }
}

final class LinkMetricsTests: XCTestCase {
    func testKernelRTTIsPreferredOverQueuedPings() {
        var ping = LatencyStats(window: 10)
        [0.2, 0.2, 9, 12, 0.3].forEach { ping.add(ms: $0) }
        let tcp = TCPInfo(sentPackets: 10, retransmittedPackets: 0, rttMs: 1, rttVarMs: 0.5)
        let m = LinkMetrics.latencyAndJitter(tcp: tcp, ping: ping)
        XCTAssertEqual(m.latencyMs, 1)
        XCTAssertEqual(m.jitterMs, 0.5)
    }

    func testPingsAreUsedWithoutTCPInfo() {
        var ping = LatencyStats(window: 10)
        [1, 2, 3].forEach { ping.add(ms: $0) }
        let m = LinkMetrics.latencyAndJitter(tcp: nil, ping: ping)
        XCTAssertEqual(m.latencyMs, 3)
        XCTAssertEqual(m.jitterMs, ping.jitter)
    }
}

final class RoutePlannerTests: XCTestCase {
    private let locals = [
        LocalInterface(name: "en0", ip: "192.168.10.31", netmask: "255.255.255.0", kind: .wifi),
        LocalInterface(name: "bridge0", ip: "169.254.20.5", netmask: "255.255.0.0", kind: .thunderbolt),
        LocalInterface(name: "en5", ip: "169.254.99.1", netmask: "255.255.0.0", kind: .usb),
        LocalInterface(name: "bridge100", ip: "192.168.139.3", netmask: "255.255.255.0", kind: .unsupported),
        LocalInterface(name: "en8", ip: "192.168.10.77", netmask: "255.255.255.0", kind: .ethernet),
    ]

    func testThunderboltFirstThenUSBThenEthernetThenWiFi() {
        let routes = RoutePlanner.plan(local: locals, remote: ["192.168.10.40", "169.254.7.7", "fe80::1"].map { RemoteAddress($0) })
        XCTAssertEqual(routes.map(\.interface), ["bridge0", "en5", "en8", "en0"])
        XCTAssertEqual(routes.map(\.address), ["169.254.7.7", "169.254.7.7", "192.168.10.40", "192.168.10.40"])
    }

    func testNoSharedSubnetMeansNoRoute() {
        let routes = RoutePlanner.plan(local: locals, remote: ["10.0.0.9"].map { RemoteAddress($0) })
        XCTAssertTrue(routes.isEmpty)
    }

    func testSameMacUsesLoopback() {
        let routes = RoutePlanner.plan(local: locals, remote: ["192.168.10.31"].map { RemoteAddress($0) })
        XCTAssertEqual(routes.first?.interface, "lo0")
        XCTAssertEqual(routes.first?.address, "127.0.0.1")
    }

    func testARepairByeDeletesNoKeyAndOnlyMarksTheReceiver() {
        XCTAssertEqual(SenderSession.disownedBy(Bye(reason: "keys differ", repair: true), receiverID: "imac"), ["imac"])
        XCTAssertEqual(SenderSession.disownedBy(Bye(reason: "stopped"), receiverID: "imac"), [])
        XCTAssertTrue(SenderSession.expectsProof(pairedTarget: true, pairedReceiver: false, pairedName: false),
                      "the key stays: a look-alike's bye cannot lift the proof")
    }

    func testIPv6OnlyCableRoutesWhereMDNSAnswered() {
        let locals = [LocalInterface(name: "bridge0", ip: "", netmask: "", kind: .thunderbolt, v6: ["fe80::1c2"]),
                      LocalInterface(name: "en0", ip: "192.168.0.179", netmask: "255.255.255.0", kind: .wifi)]
        let remote = [RemoteAddress("fe80::8a%bridge0", via: "bridge0"), RemoteAddress("192.168.0.152", via: "en0")]
        let routes = RoutePlanner.plan(local: locals, remote: remote)
        XCTAssertEqual(routes.map(\.interface), ["bridge0", "en0"])
        XCTAssertEqual(routes.first?.address, "fe80::8a%bridge0", "scoped: the socket binds that interface")
        XCTAssertEqual(RoutePlanner.plan(local: locals, remote: [RemoteAddress("fe80::1c2%bridge0", via: "bridge0")]).first?.kind, .loopback,
                       "its own IPv6 address: same Mac")
    }

    func testLinkLocalAddressesUseTheInterfaceThatAnswered() {
        let locals = [
            LocalInterface(name: "bridge0", ip: "169.254.18.130", netmask: "255.255.0.0", kind: .thunderbolt),
            LocalInterface(name: "en5", ip: "169.254.99.1", netmask: "255.255.0.0", kind: .usb),
            LocalInterface(name: "en12", ip: "169.254.240.86", netmask: "255.255.0.0", kind: .ethernet),
            LocalInterface(name: "en0", ip: "192.168.0.179", netmask: "255.255.255.0", kind: .wifi),
        ]
        let remote = [RemoteAddress("169.254.174.145", via: "en5"), RemoteAddress("169.254.240.6", via: "en12"),
                      RemoteAddress("192.168.0.152", via: "en0")]
        let routes = RoutePlanner.plan(local: locals, remote: remote)
        XCTAssertEqual(routes.map(\.interface), ["en5", "en12", "en0"], "nothing answered on bridge0")
        XCTAssertEqual(routes.map(\.address), ["169.254.174.145", "169.254.240.6", "192.168.0.152"])
    }

    private let threeLinks = [Route(interface: "en5", address: "169.254.174.145", kind: .usb),
                              Route(interface: "en12", address: "169.254.240.6", kind: .ethernet),
                              Route(interface: "en0", address: "192.168.0.152", kind: .wifi)]

    func testAvailableLinksInPreferenceOrderWithoutRepeats() {
        XCTAssertEqual(RoutePlanner.kinds(threeLinks + [Route(interface: "en7", address: "169.254.1.1", kind: .ethernet)]),
                       [.usb, .ethernet, .wifi])
    }

    func testAChosenLinkKeepsOnlyItsRoutes() {
        let chosen = RoutePlanner.select(threeLinks, prefer: .wifi)
        XCTAssertEqual(chosen.routes.map(\.interface), ["en0"])
        XCTAssertFalse(chosen.fellBack)
        XCTAssertEqual(RoutePlanner.select(threeLinks, prefer: nil).routes, threeLinks)
    }

    func testAChosenLinkThatIsGoneFallsBackToTheFastest() {
        let chosen = RoutePlanner.select(threeLinks, prefer: .thunderbolt)
        XCTAssertEqual(chosen.routes, threeLinks)
        XCTAssertTrue(chosen.fellBack)
    }

    func testOnlyAChosenLinkThatAnswersHasFallbackRoutes() {
        XCTAssertEqual(RoutePlanner.fallback(threeLinks, prefer: .wifi).map(\.interface), ["en5", "en12"])
        XCTAssertEqual(RoutePlanner.fallback(threeLinks, prefer: nil), [], "automatic already tries every route")
        XCTAssertEqual(RoutePlanner.fallback(threeLinks, prefer: .thunderbolt), [], "a gone link already fell back to all")
    }

    func testUnsupportedInterfacesAreSkipped() {
        let routes = RoutePlanner.plan(local: locals, remote: ["192.168.139.9"].map { RemoteAddress($0) })
        XCTAssertTrue(routes.isEmpty)
    }
}

final class CompressionPolicyTests: XCTestCase {
    private let fullFrame = 14_745_600 // 5K raw BC7 bytes: 7.1 Gbps at 60 fps

    func testFramesTheLinkCarriesGoStored() {
        var p = CompressionPolicy(capacityGbps: 8, fps: 60)
        XCTAssertEqual(p.next(rawBytes: fullFrame / 3, queueWasFull: false), .none)
        var fast = CompressionPolicy(capacityGbps: 40, fps: 60)
        XCTAssertEqual(fast.next(rawBytes: fullFrame, queueWasFull: false), .none)
    }

    func testFramesTooBigForTheLinkAreCompressed() {
        var p = CompressionPolicy(capacityGbps: 8, fps: 60)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
        p.record(rawBytes: fullFrame, wireBytes: fullFrame / 4)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
    }

    func testIncompressibleContentIsSentStoredAndProbedWithOneChunk() {
        var p = CompressionPolicy(capacityGbps: 8, fps: 60)
        _ = p.next(rawBytes: fullFrame, queueWasFull: false)
        p.record(rawBytes: fullFrame, wireBytes: fullFrame - 1000)
        let decisions = (0..<CompressionPolicy.probeInterval).map { _ in p.next(rawBytes: fullFrame, queueWasFull: false) }
        XCTAssertEqual(Array(decisions.dropLast()), Array(repeating: .none, count: CompressionPolicy.probeInterval - 1))
        XCTAssertEqual(decisions.last, .firstChunk)
        p.record(rawBytes: 1_000_000, wireBytes: 200_000)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
    }

    func testCongestionCompressesForAWhile() {
        var p = CompressionPolicy(capacityGbps: 40, fps: 60)
        XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: true), .all)
        for _ in 1..<CompressionPolicy.congestionFrames { XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: false), .all) }
        XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: false), .none)
    }
}

final class DiscoveryTests: XCTestCase {
    /// A resolved receiver, without the network
    private final class Resolved: NetService {
        override var port: Int { 4000 }
    }

    private func service(_ name: String) -> NetService {
        Resolved(domain: "local.", type: AfterscreenProtocol.bonjourType + ".", name: name)
    }

    func testAnUnresolvedPortIsIgnored() {
        let discovery = Discovery()
        var list: [DiscoveredReceiver]?
        discovery.onChange = { list = $0 }
        discovery.netServiceDidResolveAddress(NetService(domain: "local.", type: AfterscreenProtocol.bonjourType + ".", name: "iMac"))
        XCTAssertNil(list)
    }

    func testAReceiverStaysListedWhileAnyInterfaceReportsIt() {
        let discovery = Discovery()
        var list: [DiscoveredReceiver] = []
        discovery.onChange = { list = $0 }
        let browser = NetServiceBrowser()
        // The browser reports one instance per interface, e.g. Thunderbolt Bridge and Wi-Fi
        let bridge = service("iMac"), wifi = service("iMac")
        discovery.netServiceBrowser(browser, didFind: bridge, moreComing: true)
        discovery.netServiceBrowser(browser, didFind: wifi, moreComing: false)
        discovery.netServiceDidResolveAddress(bridge)
        XCTAssertEqual(list.map(\.name), ["iMac"])

        discovery.netServiceBrowser(browser, didRemove: bridge, moreComing: false)
        XCTAssertEqual(list.map(\.name), ["iMac"], "still reachable over Wi-Fi")
        discovery.netServiceBrowser(browser, didRemove: wifi, moreComing: false)
        XCTAssertEqual(list.map(\.name), [])
    }
}
