import XCTest
@testable import AfterscreenCore

final class MacModelsTests: XCTestCase {
    func testSupportedMacsHaveTheirNames() {
        XCTAssertEqual(MacModels.name(for: "iMac18,3"), "iMac (Retina 5K, 27-inch, 2017)")
        XCTAssertEqual(MacModels.name(for: "iMacPro1,1"), "iMac Pro (Retina 5K, 27-inch, Late 2017)")
        XCTAssertEqual(MacModels.name(for: "MacBookAir10,1"), "MacBook Air (M1, 2020)")
        XCTAssertEqual(MacModels.name(for: "Mac17,9"), "MacBook Pro (14-inch, M5 Pro or M5 Max)")
        XCTAssertEqual(MacModels.name(for: "Mac17,5"), "MacBook Neo")
    }

    func testOthersShowTheIdentifier() {
        // Newer than the table, or outside the supported range
        XCTAssertEqual(MacModels.name(for: "Mac99,1"), "Mac99,1")
        XCTAssertEqual(MacModels.name(for: "MacBookPro16,1"), "MacBookPro16,1")
        XCTAssertEqual(MacModels.name(for: "iMac13,2"), "iMac13,2")
        // Unreleased and developer-only hardware
        XCTAssertEqual(MacModels.name(for: "Mac15,1"), "Mac15,1")
        XCTAssertEqual(MacModels.name(for: "ADP3,2"), "ADP3,2")
    }
}
