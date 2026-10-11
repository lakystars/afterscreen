import XCTest
@testable import AfterscreenSenderKit

final class QualityNoticeTests: XCTestCase {
    private var notice = QualityNotice()
    private var lastShown: TimeInterval?
    private var clock: TimeInterval = 1000

    /// Seconds at `share` of an 80 Mbps start; notices shown
    private func run(_ seconds: Int, at share: Double) -> Int {
        (0..<seconds).filter { _ in
            clock += 1
            return notice.update(bitrate: Int(80_000_000 * share), start: 80_000_000, now: clock, lastShown: &lastShown)
        }.count
    }

    func testShortDipsPassUnannounced() {
        XCTAssertEqual(run(4, at: 0.3), 0)
        XCTAssertEqual(run(1, at: 0.7), 0)
        XCTAssertEqual(run(4, at: 0.5), 0)
        XCTAssertFalse(notice.lowered)
    }

    func testFiveSevereSecondsShowOnceAnEpisode() {
        XCTAssertEqual(run(5, at: 0.4), 1)
        XCTAssertTrue(notice.lowered)
        XCTAssertEqual(run(20, at: 0.2), 0, "same episode")
        XCTAssertEqual(run(29, at: 0.95), 0)
        XCTAssertTrue(notice.lowered, "recovering, not yet recovered")
        XCTAssertEqual(run(1, at: 0.95), 0)
        XCTAssertFalse(notice.lowered)
    }

    func testTenQuietMinutesBetweenNotices() {
        XCTAssertEqual(run(5, at: 0.4), 1)
        _ = run(30, at: 1)
        XCTAssertEqual(run(5, at: 0.4), 0, "a new episode inside ten minutes stays quiet")
        XCTAssertTrue(notice.lowered, "the popover still shows it")
        _ = run(30, at: 1)
        clock += 600
        XCTAssertEqual(run(5, at: 0.4), 1)
    }
}
