import XCTest
@testable import AfterscreenCore

final class AppVersionTests: XCTestCase {
    func testTagsReadAsVersions() {
        XCTAssertEqual(AppVersion.parts("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(AppVersion.parts("1.10"), [1, 10])
        XCTAssertNil(AppVersion.parts("v1.2.3-beta"))
        XCTAssertNil(AppVersion.parts("1..2"))
        XCTAssertNil(AppVersion.parts("1.2.3.4"))
        XCTAssertNil(AppVersion.parts("+1.2"))
        XCTAssertNil(AppVersion.parts("１.2"))
        XCTAssertNil(AppVersion.parts("1.99999999999999999999"))
    }

    func testNewerComparesNumbers() {
        XCTAssertTrue(AppVersion.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("v1.1", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("v1.0.0", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("junk", than: "1.0.0"))
    }
}
