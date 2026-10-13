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

    func testIntelMacsOnCatalinaHaveTheirNames() {
        XCTAssertEqual(MacModels.name(for: "iMac13,2"), "iMac (27-inch, Late 2012)")
        XCTAssertEqual(MacModels.name(for: "MacBookAir5,1"), "MacBook Air (11-inch, Mid 2012)")
        XCTAssertEqual(MacModels.name(for: "MacBookPro12,1"), "MacBook Pro (Retina, 13-inch, Early 2015)")
        XCTAssertEqual(MacModels.name(for: "MacBookPro16,1"), "MacBook Pro (16-inch, 2019)")
        XCTAssertEqual(MacModels.name(for: "MacBook8,1"), "MacBook (Retina, 12-inch, Early 2015)")
        XCTAssertEqual(MacModels.name(for: "Macmini6,1"), "Mac mini (Late 2012, Core i5)")
        XCTAssertEqual(MacModels.name(for: "MacPro6,1"), "Mac Pro (Late 2013)")
        // One identifier, two releases
        XCTAssertEqual(MacModels.name(for: "MacBookAir7,2"), "MacBook Air (13-inch, Early 2015 or 2017)")
    }

    func testOthersShowTheIdentifier() {
        // Newer than the table, or outside the supported range
        XCTAssertEqual(MacModels.name(for: "Mac99,1"), "Mac99,1")
        // Last on macOS 10.13 or 10.14
        XCTAssertEqual(MacModels.name(for: "MacBookPro8,1"), "MacBookPro8,1")
        XCTAssertEqual(MacModels.name(for: "iMac12,2"), "iMac12,2")
        XCTAssertEqual(MacModels.name(for: "MacPro5,1"), "MacPro5,1")
        // Unreleased and developer-only hardware
        XCTAssertEqual(MacModels.name(for: "Mac15,1"), "Mac15,1")
        XCTAssertEqual(MacModels.name(for: "Macmini8,2"), "Macmini8,2")
        XCTAssertEqual(MacModels.name(for: "ADP3,2"), "ADP3,2")
    }
}
