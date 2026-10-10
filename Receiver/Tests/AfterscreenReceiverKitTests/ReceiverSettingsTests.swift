import AfterscreenCore
import XCTest
@testable import AfterscreenReceiverKit

final class ReceiverSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var agents: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "afterscreen-receiver-tests-\(UUID().uuidString)")
        agents = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: agents)
    }

    private func settings() -> ReceiverSettings {
        ReceiverSettings(defaults: defaults, agentDirectory: agents, executable: "/Applications/Afterscreen Receiver.app/Contents/MacOS/Afterscreen Receiver")
    }

    func testDefaultsAndPersistence() {
        let s = settings()
        XCTAssertEqual(s.accept, .any)
        XCTAssertEqual(s.onDisconnect, .showDesktop)
        s.accept = .wired
        s.onDisconnect = .sleepDisplay
        let again = settings()
        XCTAssertEqual(again.accept, .wired)
        XCTAssertEqual(again.onDisconnect, .sleepDisplay)
    }

    func testWiredOnlyRefusesWiFi() {
        let s = settings()
        XCTAssertTrue(s.accepts(.wifi))
        s.accept = .wired
        XCTAssertFalse(s.accepts(.wifi))
        XCTAssertFalse(s.accepts(.unsupported))
        for kind in [LinkKind.thunderbolt, .usb, .ethernet, .loopback] { XCTAssertTrue(s.accepts(kind), "\(kind)") }
    }

    func testOpenAtLoginWritesAndRemovesALaunchAgent() throws {
        let s = settings()
        XCTAssertFalse(s.launchAtLogin)
        s.launchAtLogin = true
        XCTAssertTrue(s.launchAtLogin)
        let file = agents.appendingPathComponent("io.github.lakystars.afterscreen.receiver.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "io.github.lakystars.afterscreen.receiver")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Applications/Afterscreen Receiver.app/Contents/MacOS/Afterscreen Receiver"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        s.launchAtLogin = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
