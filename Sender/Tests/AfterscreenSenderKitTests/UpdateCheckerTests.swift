import XCTest
@testable import AfterscreenSenderKit

final class UpdateCheckerTests: XCTestCase {
    func testOnlyPublishedVersionTagsCount() {
        XCTAssertEqual(UpdateChecker.tag(from: Data(#"{"tag_name":"v1.2.0","draft":false,"prerelease":false}"#.utf8)), "v1.2.0")
        XCTAssertNil(UpdateChecker.tag(from: Data(#"{"tag_name":"v1.2.0","prerelease":true}"#.utf8)))
        XCTAssertNil(UpdateChecker.tag(from: Data(#"{"tag_name":"nightly"}"#.utf8)))
        XCTAssertNil(UpdateChecker.tag(from: Data("not json".utf8)))
    }

    func testThePageIsThisRepositorysRelease() {
        XCTAssertEqual(UpdateChecker.page(for: "v1.2.0")?.absoluteString, "https://github.com/lakystars/afterscreen/releases/tag/v1.2.0")
    }

    func testUpdateNamesTheSidesItUpdates() {
        XCTAssertEqual(UpdateChecker.update(tag: "v1.2.0", installed: "1.1.0", receiver: nil)?.mac, true)
        XCTAssertEqual(UpdateChecker.update(tag: "v1.2.0", installed: "1.1.0", receiver: nil)?.receiver, false)
        let both = UpdateChecker.update(tag: "v1.2.0", installed: "1.1.0", receiver: "1.0.0")
        XCTAssertEqual(both.map { [$0.mac, $0.receiver] }, [true, true])
        XCTAssertEqual(both?.version, "1.2.0")
        XCTAssertEqual(UpdateChecker.update(tag: "v1.1.0", installed: "1.1.0", receiver: "1.0.0").map { [$0.mac, $0.receiver] }, [false, true])
        XCTAssertNil(UpdateChecker.update(tag: "v1.1.0", installed: "1.1.0", receiver: "1.1.0"))
        XCTAssertNil(UpdateChecker.update(tag: "v1.1.0", installed: nil, receiver: nil))
    }
}
