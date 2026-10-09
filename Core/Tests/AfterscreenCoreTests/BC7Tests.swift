import XCTest
@testable import AfterscreenCore

final class BC7Tests: XCTestCase {
    private func decode(_ block: [UInt8]) -> [UInt8] {
        block.withUnsafeBytes { BC7.decodeBlock($0) }
    }

    func testMode6ByteZeroHasModeBit() {
        let block = BC7.makeMode6(e0: (0, 0, 0, 127), e1: (0, 0, 0, 127), p0: 0, p1: 0, indices: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(block.count, 16)
        XCTAssertEqual(block[0] & 0x7F, 0x40)
    }

    func testMode6FlatEndpoints() {
        let block = BC7.makeMode6(e0: (50, 75, 100, 127), e1: (50, 75, 100, 127), p0: 1, p1: 1, indices: [UInt8](repeating: 7, count: 16))
        let rgba = decode(block)
        XCTAssertEqual(rgba.count, 64)
        for i in 0..<16 {
            XCTAssertEqual(Array(rgba[i * 4..<i * 4 + 4]), [101, 151, 201, 255])
        }
    }

    func testMode6Interpolation() {
        let weights: [Int] = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]
        let block = BC7.makeMode6(e0: (0, 0, 0, 127), e1: (127, 127, 127, 127), p0: 0, p1: 1,
                                  indices: (0..<16).map { UInt8($0) })
        let rgba = decode(block)
        for i in 0..<16 {
            let e0 = 0, e1 = 255
            let expected = UInt8(((64 - weights[i]) * e0 + weights[i] * e1 + 32) >> 6)
            XCTAssertEqual(rgba[i * 4], expected, "pixel \(i)")
            XCTAssertEqual(rgba[i * 4 + 1], expected)
            XCTAssertEqual(rgba[i * 4 + 2], expected)
        }
        // Alpha: e0 = 254 (p0 = 0), e1 = 255
        XCTAssertEqual(rgba[3], 254)
        XCTAssertEqual(rgba[63], 255)
    }

    func testAnchorIndexStoredInThreeBits() {
        // Index 0 above 7 cannot be represented; the builder must reject it
        let block = BC7.makeMode6(e0: (1, 2, 3, 127), e1: (4, 5, 6, 127), p0: 0, p1: 0,
                                  indices: [7] + [UInt8](repeating: 15, count: 15))
        let rgba = decode(block)
        // Pixel 1 uses index 15 → e1 = (8, 10, 12)
        XCTAssertEqual(Array(rgba[4..<7]), [8, 10, 12])
    }

    func testNonMode6DecodesToMagenta() {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 0x01 // mode 0
        let rgba = decode(block)
        XCTAssertEqual(Array(rgba[0..<4]), [255, 0, 255, 255])
    }
}
