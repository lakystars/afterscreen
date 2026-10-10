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
        ReceiverSettings(defaults: defaults, agentDirectory: agents, bundleID: "io.github.lakystars.afterscreen.receiver")
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
        // An adapter the classifier does not know is still a cable
        for kind in [LinkKind.thunderbolt, .usb, .ethernet, .loopback, .unsupported] { XCTAssertTrue(s.accepts(kind), "\(kind)") }
    }

    func testOpenAtLoginWritesAndRemovesALaunchAgent() throws {
        let s = settings()
        XCTAssertFalse(s.launchAtLogin)
        s.launchAtLogin = true
        XCTAssertTrue(s.launchAtLogin)
        let file = agents.appendingPathComponent("io.github.lakystars.afterscreen.receiver.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "io.github.lakystars.afterscreen.receiver")
        // By bundle id: the app may move, or run translocated, after the login item is set
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", "-b", "io.github.lakystars.afterscreen.receiver"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        s.launchAtLogin = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
