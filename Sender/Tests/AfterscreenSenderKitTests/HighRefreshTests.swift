import Metal
import XCTest
import AfterscreenCore
@testable import AfterscreenSenderKit

final class HighRefreshTests: XCTestCase {
    private func welcome(hz: Double?) -> Welcome {
        let panel = PixelSize(width: 3024, height: 1900)
        return Welcome(protocolVersion: 1, name: "MacBook Pro", modelID: "Mac17,9", marketingName: "MacBook Pro", osVersion: "27.0", gpuNames: [],
                       panelPixels: panel, panelPoints: PixelSize(width: 1512, height: 950), hevcDecode: true, h264Decode: true, bc7: true,
                       refreshHz: hz)
    }

    func testSixtyUnlessTheExperimentIsOn() {
        let promotion = welcome(hz: 120)
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 15, welcome: promotion)?.frameRate, 60)
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 15, welcome: promotion, maxFrameRate: 120)?.frameRate, 120)
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 15, welcome: welcome(hz: 50))?.frameRate, 50, "slower panels keep theirs")
    }

    func testOnlyThunderboltToA120HzPanelIsTimed() {
        XCTAssertTrue(HighRefresh.worthTiming(enabled: true, link: .thunderbolt, receiverHz: 120, tilesFit: true))
        XCTAssertFalse(HighRefresh.worthTiming(enabled: false, link: .thunderbolt, receiverHz: 120, tilesFit: true))
        XCTAssertFalse(HighRefresh.worthTiming(enabled: true, link: .usb, receiverHz: 120, tilesFit: true))
        XCTAssertFalse(HighRefresh.worthTiming(enabled: true, link: .thunderbolt, receiverHz: 100, tilesFit: true), "the label promises 120")
        XCTAssertFalse(HighRefresh.worthTiming(enabled: true, link: .thunderbolt, receiverHz: 120, tilesFit: false))
    }

    func testTheEncoderMustLeaveHalfTheFrame() {
        func verdict(_ link: LinkKind = .thunderbolt, hz: Double = 120, fits: Bool = true, ms: Double?) -> HighRefresh.Verdict? {
            HighRefresh.verdict(enabled: true, link: link, receiverHz: hz, gbps: 1.5, tilesFit: fits, encodeMs: ms)
        }
        XCTAssertEqual(verdict(ms: 1.4), .high(ms: 1.4))
        XCTAssertEqual(verdict(ms: 4.8), .encoderBusy(ms: 4.8))
        XCTAssertEqual(verdict(ms: nil), .encoderBusy(ms: nil))
        XCTAssertEqual(verdict(.ethernet, ms: nil), .needsThunderbolt)
        XCTAssertEqual(verdict(fits: false, ms: nil), .linkTooSlow(gbps: 1.5), "lossless tiles at 120 would turn hybrid")
        XCTAssertNil(verdict(hz: 100, ms: 1))
        XCTAssertNil(HighRefresh.verdict(enabled: false, link: .thunderbolt, receiverHz: 120, gbps: 15, tilesFit: true, encodeMs: 1))
    }

    func testTheCeilingIs120() {
        XCTAssertEqual(HighRefresh.maxFrameRate(.high(ms: 1)), 120)
        XCTAssertEqual(HighRefresh.maxFrameRate(.encoderBusy(ms: 9)), 60)
        XCTAssertEqual(HighRefresh.maxFrameRate(nil), 60)
        XCTAssertEqual(PathPolicy.choose(link: .thunderbolt, capacityGbps: 15, welcome: welcome(hz: 144), maxFrameRate: 120)?.frameRate, 120)
    }
}

final class TileCapacityTests: XCTestCase {
    /// `swift test --filter TileCapacityTests` prints this Mac's figure
    func testTheProbeTimesAFullMotionFrame() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "needs Metal")
        let size = PixelSize(width: 3024, height: 1900)
        let ms = try XCTUnwrap(TileCapacity.fullMotionMs(size, limitMs: .infinity))
        print("[tile capacity] 3024x1900 full motion: \(String(format: "%.2f", ms)) ms per frame")
        XCTAssertGreaterThan(ms, 0)
        XCTAssertEqual(TileCapacity.fullMotionMs(size, limitMs: .infinity), ms, "kept, not timed again")
        XCTAssertEqual(TileCapacity.fullMotionMs(size, limitMs: 0), ms, "a slow result is kept for a while too")
    }
}
