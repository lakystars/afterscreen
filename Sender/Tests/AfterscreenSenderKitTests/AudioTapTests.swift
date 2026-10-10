import XCTest
@testable import AfterscreenSenderKit

final class AudioConversionTests: XCTestCase {
    func testPlanarFloatBecomesInterleavedInt16WithClipping() {
        let left: [Float] = [0, 0.5, 1.5], right: [Float] = [-0.5, -1, -2]
        let out = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in AudioConvert.interleave([l, r]) } }
        XCTAssertEqual(out, [0, -16384, 16384, -32767, 32767, -32767])
    }
}
