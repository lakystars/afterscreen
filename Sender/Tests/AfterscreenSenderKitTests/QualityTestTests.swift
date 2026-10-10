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
        XCTAssertEqual(QualityTest.verdict(r)?.size, PixelSize(width: 5120, height: 2880))
        XCTAssertEqual(QualityTest.verdict(Array(r.prefix(3)))?.size, PixelSize(width: 2560, height: 1440))
        XCTAssertNil(QualityTest.verdict([QualityTest.Stage(size: PixelSize(width: 1920, height: 1080), fps: 30, gbps: 0.1)]))
    }

    func testWarmUpCoversTwoLosslessFramesOnSlowLinks() {
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 3.77), 1.06, accuracy: 0.01)
        // 14.7 MB of BC7 twice at 0.14 Gb/s
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 0.14), 2.69, accuracy: 0.01)
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 5120, height: 2880), capacityGbps: 0.01), 5)
        XCTAssertEqual(QualityTest.warmup(stage: PixelSize(width: 1920, height: 1080), capacityGbps: nil), 5)
    }

    func testPatternChangesEveryTileEveryFrame() throws {
        let pattern = try XCTUnwrap(TestPattern())
        let size = PixelSize(width: 256, height: 128)
        let a = try XCTUnwrap(pattern.frame(size: size, time: 0)), b = try XCTUnwrap(pattern.frame(size: size, time: 1.0 / 60))
        XCTAssertEqual(CVPixelBufferGetWidth(a), 256)
        XCTAssertEqual(CVPixelBufferGetHeight(a), 128)
        func tiles(_ pb: CVPixelBuffer) -> [[UInt8]] {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
            return (0..<8).map { t in
                (0..<64).flatMap { y in Array(UnsafeBufferPointer(start: base + ((t / 4) * 64 + y) * stride + (t % 4) * 256, count: 256)) }
            }
        }
        XCTAssertTrue(zip(tiles(a), tiles(b)).allSatisfy { $0 != $1 })
    }
}
