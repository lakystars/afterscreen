import CoreVideo
import Metal
import AfterscreenCore
import XCTest
@testable import AfterscreenSenderKit

final class QualityTestTests: XCTestCase {
    func testStagesScaleThePanel() {
        XCTAssertEqual(QualityTest.stages(panel: PixelSize(width: 5120, height: 2880)),
                       [PixelSize(width: 1920, height: 1080), PixelSize(width: 2560, height: 1440),
                        PixelSize(width: 3840, height: 2160), PixelSize(width: 5120, height: 2880)])
        XCTAssertEqual(QualityTest.stages(panel: PixelSize(width: 4096, height: 2304)).last, PixelSize(width: 4096, height: 2304))
        XCTAssertEqual(QualityTest.stages(panel: PixelSize(width: 2560, height: 1440)).first, PixelSize(width: 960, height: 540))
    }

    func testLabels() {
        XCTAssertEqual(QualityTest.label(PixelSize(width: 5120, height: 2880)), "5K")
        XCTAssertEqual(QualityTest.label(PixelSize(width: 4096, height: 2304)), "4K")
        XCTAssertEqual(QualityTest.label(PixelSize(width: 3840, height: 2160)), "4K")
        XCTAssertEqual(QualityTest.label(PixelSize(width: 2560, height: 1440)), "1440p")
    }

    func testVerdictIsTheLargestStageThatHoldsFrameRate() {
        let r = [QualityTest.Stage(size: PixelSize(width: 1920, height: 1080), fps: 60, gbps: 0.4),
                 QualityTest.Stage(size: PixelSize(width: 2560, height: 1440), fps: 59, gbps: 0.6),
                 QualityTest.Stage(size: PixelSize(width: 3840, height: 2160), fps: 41, gbps: 0.9),
                 QualityTest.Stage(size: PixelSize(width: 5120, height: 2880), fps: 56, gbps: 1.1)]
        XCTAssertEqual(QualityTest.verdict(r, frameRate: 60)?.size, PixelSize(width: 5120, height: 2880))
        XCTAssertEqual(QualityTest.verdict(Array(r.prefix(3)), frameRate: 60)?.size, PixelSize(width: 2560, height: 1440))
        XCTAssertNil(QualityTest.verdict([QualityTest.Stage(size: PixelSize(width: 1920, height: 1080), fps: 30, gbps: 0.1)], frameRate: 60))
        XCTAssertNotNil(QualityTest.verdict([QualityTest.Stage(size: PixelSize(width: 1920, height: 1080), fps: 46, gbps: 0.1)], frameRate: 50),
                        "46 of 50 Hz is smooth")
    }

    func testWarmUpCoversTwoLosslessFramesOnSlowLinks() {
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 3.77), 1.06, accuracy: 0.01)
        // 14.7 MB of BC7 twice at 0.14 Gb/s
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 0.14), 2.69, accuracy: 0.01)
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 0.01), 5)
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 1920, height: 1080), capacityGbps: nil), 5)
    }

    func testCaptionsNameTheStage() {
        XCTAssertEqual(QualityTest.caption(PixelSize(width: 2560, height: 1440), link: .wifi, step: 2, of: 5, typical: false),
                       "Wi-Fi · 1440p · 2/5 · Full motion")
        XCTAssertEqual(QualityTest.caption(PixelSize(width: 4096, height: 2304), link: .ethernet, step: 5, of: 5, typical: true),
                       "Ethernet · Typical use · 4096×2304 · 5/5")
    }

    func testTypicalUseStaysOutOfTheVerdict() {
        var r = QualityTest.Report(receiver: "iMac")
        r.stages = [QualityTest.Stage(size: PixelSize(width: 1920, height: 1080), fps: 30, gbps: 0.1)]
        r.typical = QualityTest.Stage(size: PixelSize(width: 4096, height: 2304), fps: 60, gbps: 0.1)
        XCTAssertNil(r.verdict)
        XCTAssertEqual(r.done, 2)
    }

    /// 64-px tiles that differ between two frames, of all tiles
    private func changedTiles(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (changed: Int, total: Int, tiles: [CGRect]) {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a), stride = CVPixelBufferGetBytesPerRow(a)
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        var tiles: [CGRect] = [], total = 0
        for ty in Swift.stride(from: 0, to: h, by: 64) {
            for tx in Swift.stride(from: 0, to: w, by: 64) {
                total += 1
                let rows = ty..<min(ty + 64, h)
                if rows.contains(where: { memcmp(pa + $0 * stride + tx * 4, pb + $0 * stride + tx * 4, min(64, w - tx) * 4) != 0 }) {
                    tiles.append(CGRect(x: tx, y: ty, width: min(64, w - tx), height: rows.count))
                }
            }
        }
        return (tiles.count, total, tiles)
    }

    func testFullMotionChangesEveryTileEveryFrame() throws {
        let pattern = try XCTUnwrap(TestPattern())
        let size = PixelSize(width: 256, height: 128)
        let stage = TestPattern.Stage(caption: "1080p · 1/5 · Full motion", frameRate: 60, motion: .full)
        let a = try XCTUnwrap(pattern.frame(size: size, index: 0, stage: stage))
        let b = try XCTUnwrap(pattern.frame(size: size, index: 1, stage: stage))
        XCTAssertEqual(CVPixelBufferGetWidth(a), 256)
        XCTAssertEqual(CVPixelBufferGetHeight(a), 128)
        let c = changedTiles(a, b)
        XCTAssertEqual(c.changed, c.total)
    }

    func testTypicalUseMovesAboutAThird() throws {
        let pattern = try XCTUnwrap(TestPattern())
        let size = PixelSize(width: 1920, height: 1080)
        let stage = TestPattern.Stage(caption: "Typical use · 1920×1080 · 5/5", frameRate: 60, motion: .typical)
        let a = try XCTUnwrap(pattern.frame(size: size, index: 100, stage: stage))
        let b = try XCTUnwrap(pattern.frame(size: size, index: 101, stage: stage))
        let c = changedTiles(a, b)
        let share = Double(c.changed) / Double(c.total)
        XCTAssertGreaterThan(share, 0.2)
        XCTAssertLessThan(share, 0.5)
        // Changes outside the dirty rects would stay stale on the receiver
        let rects = try XCTUnwrap(pattern.changing(size: size, stage: stage))
        for tile in c.tiles where !rects.contains(where: { $0.intersects(tile) }) {
            XCTFail("tile \(tile) changed outside the dirty rects")
        }
    }
}
