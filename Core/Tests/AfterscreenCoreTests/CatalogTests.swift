import XCTest
@testable import AfterscreenCore

final class CatalogTests: XCTestCase {
    /// The repository's Localization folder, as the app bundle holds it
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization")

    private var saved: (language: Language, bundle: Bundle) = (.system, .main)

    override func setUp() {
        saved = (L10n.language, L10n.catalogBundle)
        L10n.catalogBundle = Bundle(path: CatalogTests.folder.path)!
    }

    override func tearDown() {
        L10n.language = saved.language
        L10n.catalogBundle = saved.bundle
    }

    func testKoreanReadsItsTable() {
        L10n.language = .korean
        XCTAssertEqual(L10n.s("Remove"), "해제")
    }

    func testEnglishShowsTheKey() {
        L10n.language = .english
        XCTAssertEqual(L10n.s("Remove"), "Remove")
    }

    func testAMissingKeyShowsTheKey() {
        L10n.language = .korean
        XCTAssertEqual(L10n.s("Not in any table"), "Not in any table")
        XCTAssertEqual(L10n.s("Not in any table: %@", "x"), "Not in any table: x")
    }

    func testArgumentsFillThePlaceholders() {
        L10n.language = .korean
        XCTAssertEqual(L10n.s("%@ settings", "iMac"), "iMac 설정")
        XCTAssertEqual(L10n.s("Other receivers (%lld)", 3), "다른 수신기 (3)")
        XCTAssertEqual(L10n.s("Automatic: %@'s own panel first. %@", "iMac", "Applies."), "자동: iMac 자체 화면 우선. Applies.")
        L10n.language = .english
        XCTAssertEqual(L10n.s("Other receivers (%lld)", 3), "Other receivers (3)")
    }

    func testSystemPicksAnOfferedLanguageInPreferenceOrder() {
        let available = ["ko"]
        XCTAssertEqual(L10n.code(for: .system, available: available, preferred: ["ko-KR", "en-US"]), "ko")
        // English is always offered, though it has no folder
        XCTAssertEqual(L10n.code(for: .system, available: available, preferred: ["en-US", "ko-KR"]), "en")
        XCTAssertEqual(L10n.code(for: .system, available: available, preferred: ["ja-JP"]), "en")
        XCTAssertEqual(L10n.code(for: .system, available: available, preferred: []), "en")
        XCTAssertEqual(L10n.code(for: .korean, available: [], preferred: ["en-US"]), "ko")
        XCTAssertEqual(L10n.code(for: .english, available: available, preferred: ["ko-KR"]), "en")
    }

    func testSystemFollowsTheSecondPreferenceWhenTheFirstIsNotOffered() {
        XCTAssertEqual(L10n.code(for: .system, available: ["ko"], preferred: ["ja-JP", "ko-KR"]), "ko")
    }

    func testEveryCallShowsTheSameLanguage() {
        L10n.language = .system
        let korean = L10n.s("Remove") == "해제"
        XCTAssertEqual(L10n.t("Remove", "해제"), L10n.s("Remove"))
        XCTAssertEqual(L10n.shown, korean ? .korean : .english)
    }
}
