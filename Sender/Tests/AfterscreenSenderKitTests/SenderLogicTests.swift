import AppKit
import CoreGraphics
import AfterscreenCore
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

final class CursorNormalizeTests: XCTestCase {
    let bounds = CGRect(x: 1800, y: -592, width: 2560, height: 1440)

    func testInsideIsNormalizedTopLeft() {
        let r = CursorTracker.normalize(point: CGPoint(x: 1800 + 640, y: -592 + 360), displayBounds: bounds)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(r.y, 0.25, accuracy: 1e-6)
        XCTAssertTrue(r.visible)
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

    func testThunderboltWithCapacityUsesTilesAtPanelPixels() {
        let c = PathPolicy.choose(link: .thunderbolt, capacityGbps: 10, welcome: welcome(panel: fiveK))
        XCTAssertEqual(c?.path, .tile)
        XCTAssertEqual(c?.streamPixels, fiveK)
        XCTAssertNil(c?.video)
        XCTAssertEqual(PathPolicy.choose(link: .ethernet, capacityGbps: 9.4, welcome: welcome(panel: fiveK))?.path, .tile)
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
        XCTAssertEqual(PathPolicy.settleTiles(capacityGbps: 0.3, tileBytes: 4096), 152)
        XCTAssertEqual(PathPolicy.settleTiles(capacityGbps: nil, tileBytes: 4096), 16)
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

final class MTUAdviceTests: XCTestCase {
    private var saved = L10n.language
    override func setUp() { saved = L10n.language; L10n.language = .english }
    override func tearDown() { L10n.language = saved }

    func testJumboFramesAreAdvisedOnWiredLinks() {
        XCTAssertEqual(LinkMetrics.mtuAdvice(mtu: 1500, link: .thunderbolt), "9000 recommended")
        XCTAssertNil(LinkMetrics.mtuAdvice(mtu: 9000, link: .thunderbolt))
        XCTAssertNil(LinkMetrics.mtuAdvice(mtu: 1500, link: .wifi))
        XCTAssertNil(LinkMetrics.mtuAdvice(mtu: nil, link: .usb))
    }

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

    func testUnsupportedInterfacesAreSkipped() {
        let routes = RoutePlanner.plan(local: locals, remote: ["192.168.139.9"].map { RemoteAddress($0) })
        XCTAssertTrue(routes.isEmpty)
    }
}

final class CompressionPolicyTests: XCTestCase {
    private let fullFrame = 14_745_600 // 5K raw BC7 bytes: 7.1 Gbps at 60 fps

    func testFramesTheLinkCarriesGoStored() {
        var p = CompressionPolicy(capacityGbps: 8)
        XCTAssertEqual(p.next(rawBytes: fullFrame / 3, queueWasFull: false), .none)
        var fast = CompressionPolicy(capacityGbps: 40)
        XCTAssertEqual(fast.next(rawBytes: fullFrame, queueWasFull: false), .none)
    }

    func testFramesTooBigForTheLinkAreCompressed() {
        var p = CompressionPolicy(capacityGbps: 8)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
        p.record(rawBytes: fullFrame, wireBytes: fullFrame / 4)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
    }

    func testIncompressibleContentIsSentStoredAndProbedWithOneChunk() {
        var p = CompressionPolicy(capacityGbps: 8)
        _ = p.next(rawBytes: fullFrame, queueWasFull: false)
        p.record(rawBytes: fullFrame, wireBytes: fullFrame - 1000)
        let decisions = (0..<CompressionPolicy.probeInterval).map { _ in p.next(rawBytes: fullFrame, queueWasFull: false) }
        XCTAssertEqual(Array(decisions.dropLast()), Array(repeating: .none, count: CompressionPolicy.probeInterval - 1))
        XCTAssertEqual(decisions.last, .firstChunk)
        p.record(rawBytes: 1_000_000, wireBytes: 200_000)
        XCTAssertEqual(p.next(rawBytes: fullFrame, queueWasFull: false), .all)
    }

    func testCongestionCompressesForAWhile() {
        var p = CompressionPolicy(capacityGbps: 40)
        XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: true), .all)
        for _ in 1..<CompressionPolicy.congestionFrames { XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: false), .all) }
        XCTAssertEqual(p.next(rawBytes: 1000, queueWasFull: false), .none)
    }
}
