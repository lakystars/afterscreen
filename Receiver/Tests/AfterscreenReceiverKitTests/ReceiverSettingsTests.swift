import AppKit
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
        XCTAssertEqual(again.presentation, .space, "a desktop of its own by default")
        again.presentation = .cover
        XCTAssertEqual(settings().presentation, .cover)
    }

    func testConnectionEffectDefaultsToTheTileWave() {
        let s = settings()
        XCTAssertEqual(s.effect, .tiles)
        s.effect = .crt
        XCTAssertEqual(settings().effect, .crt)
        XCTAssertEqual(ReceiverSettings.Effect.allCases, [.tiles, .crt, .none])
    }

    func testHUDPlacementIsRemembered() {
        let s = settings()
        XCTAssertEqual(s.hudCorner, .topRight)
        XCTAssertFalse(s.hudCollapsed)
        s.hudCorner = .bottomLeft
        s.hudCollapsed = true
        XCTAssertEqual(settings().hudCorner, .bottomLeft)
        XCTAssertTrue(settings().hudCollapsed)
    }

    func testThePointerJumpsToItsNewHotSpot() {
        // A new cursor shape moves the layer's anchor to its hot spot; an implicit animation would slide it there.
        // Implicit actions only resolve in a window's layer tree, so the check is on the table that turns them off
        let changed: Set<String> = ["anchorPoint", "position", "bounds", "contents", "hidden"]
        XCTAssertTrue(changed.isSubset(of: StreamWindow.cursorActions.keys), "\(changed.subtracting(StreamWindow.cursorActions.keys))")
    }

    func testASpaceStartsFromAWindowSoFullScreenAnimatesAsUsual() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let space = StreamWindow.Style(presentation: .space, windowed: false).initialFrame(in: screen)
        XCTAssertEqual(space.width, 1536, accuracy: 1)
        XCTAssertEqual(space.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(space.midY, screen.midY, accuracy: 1)
        XCTAssertEqual(StreamWindow.Style(presentation: .cover, windowed: false).initialFrame(in: screen), screen)
    }

    func testStreamMenuAndPointer() {
        let saved = L10n.language
        L10n.language = .english
        defer { L10n.language = saved }
        let menu = StreamWindow.makeMenu(hudShown: false, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["Stop the stream", "Show the HUD", "", "Settings…"])
        XCTAssertEqual(StreamWindow.makeMenu(hudShown: true, target: nil).items[1].title, "Hide the HUD")
        let pointer = StreamWindow.localPointer
        XCTAssertEqual(pointer.image.size, NSSize(width: 24, height: 24))
        XCTAssertEqual(pointer.hotSpot, NSPoint(x: 12, y: 12))
    }

    func testPresentationStyles() {
        let space = StreamWindow.Style(presentation: .space, windowed: false)
        XCTAssertTrue(space.mask.contains(.titled))
        XCTAssertTrue(space.behavior.contains(.fullScreenPrimary))
        XCTAssertEqual(space.level, .normal)
        XCTAssertTrue(space.fullScreen)
        let cover = StreamWindow.Style(presentation: .cover, windowed: false)
        XCTAssertEqual(cover.mask, .borderless)
        XCTAssertGreaterThan(cover.level.rawValue, NSWindow.Level.mainMenu.rawValue, "above the menu bar and Dock")
        XCTAssertFalse(cover.fullScreen)
        let windowed = StreamWindow.Style(presentation: .space, windowed: true)
        XCTAssertTrue(windowed.mask.contains(.resizable))
        XCTAssertFalse(windowed.fullScreen)
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
