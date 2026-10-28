import AppKit
import AfterscreenCore
import XCTest
@testable import AfterscreenReceiverKit

final class ReceiverSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var agents: URL!

    override func setUpWithError() throws {
        // A path: the plist stays out of ~/Library/Preferences
        suite = FileManager.default.temporaryDirectory.appendingPathComponent("afterscreen-receiver-tests-\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)
        agents = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: agents)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
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

    func testScreenChoiceIsRemembered() {
        let s = settings()
        XCTAssertNil(s.display, "automatic by default")
        XCTAssertTrue(s.matchPanelMode)
        s.display = ReceiverSettings.ChosenDisplay(key: "610-41057-1", name: "LG Ultra HD")
        s.matchPanelMode = false
        XCTAssertEqual(settings().display, ReceiverSettings.ChosenDisplay(key: "610-41057-1", name: "LG Ultra HD"))
        XCTAssertFalse(settings().matchPanelMode)
        s.display = nil
        XCTAssertNil(settings().display)
    }

    func testConnectionEffectDefaultsToTheTileWave() {
        let s = settings()
        XCTAssertEqual(s.effect, .tiles)
        s.effect = ReceiverSettings.Effect.none
        XCTAssertEqual(settings().effect, ReceiverSettings.Effect.none)
        XCTAssertEqual(ReceiverSettings.Effect.allCases, [.tiles, .none])
    }

    func testARemovedEffectFallsBackToTheTileWave() {
        defaults.set("crt", forKey: "effect")
        XCTAssertEqual(settings().effect, .tiles)
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

    private let imac = ReceiverDisplay(id: 1, key: "imac", name: "iMac", pixels: PixelSize(width: 5120, height: 2880), builtIn: true, main: true)
    private let lg = ReceiverDisplay(id: 2, key: "lg", name: "LG", pixels: PixelSize(width: 3840, height: 2160), builtIn: false, main: false)

    func testASendersEditSetsOnlyItsFields() {
        let s = settings()
        s.apply(ReceiverOptionsChange(effect: ReceiverOptions.Effect.none, onDisconnect: .sleepDisplay, launchAtLogin: true), screens: [imac, lg])
        XCTAssertEqual(s.effect, ReceiverOptions.Effect.none)
        XCTAssertEqual(s.onDisconnect, .sleepDisplay)
        XCTAssertTrue(s.launchAtLogin)
        XCTAssertEqual(s.presentation, .space, "untouched")

        s.apply(ReceiverOptionsChange(presentation: .cover, matchPanelMode: false), screens: [imac, lg])
        XCTAssertEqual(s.presentation, .cover)
        XCTAssertFalse(s.matchPanelMode)

        s.apply(ReceiverOptionsChange(screen: "gone"), screens: [imac, lg])
        XCTAssertNil(s.display, "a screen not listed changes nothing")
        s.apply(ReceiverOptionsChange(screen: "lg"), screens: [imac, lg])
        XCTAssertEqual(s.display, ReceiverSettings.ChosenDisplay(key: "lg", name: "LG"))
        s.apply(ReceiverOptionsChange(screen: ""), screens: [imac, lg])
        XCTAssertNil(s.display, "empty is automatic")
    }

    func testOnlyAnEditToTheOpenWindowsSettingsReopensIt() {
        let open = StreamWindowSettings(presentation: .space, display: 1, matchPanelMode: true)
        let cover = StreamWindowSettings(presentation: .cover, display: 1, matchPanelMode: true)
        XCTAssertTrue(StreamWindowSettings.reopens(ReceiverOptionsChange(presentation: .cover), open: open, next: cover))
        XCTAssertFalse(StreamWindowSettings.reopens(ReceiverOptionsChange(screen: ""), open: open, next: open),
                       "automatic picks the screen already shown")
        XCTAssertFalse(StreamWindowSettings.reopens(ReceiverOptionsChange(effect: .tiles), open: open, next: cover),
                       "a pending change made here waits for the next connection")
    }

    func testOptionsNameAChosenScreenThatIsGone() {
        let s = settings()
        s.display = ReceiverSettings.ChosenDisplay(key: "lg", name: "LG")
        let gone = s.options(screens: [imac], hud: true, editable: false)
        XCTAssertEqual(gone.screens, [ReceiverOptions.Screen(key: "imac", name: "iMac", pixels: PixelSize(width: 5120, height: 2880))])
        XCTAssertEqual(gone.screen, "lg")
        XCTAssertEqual(gone.missingScreen, "LG")
        XCTAssertTrue(gone.hud)
        XCTAssertFalse(gone.editable)
        XCTAssertNil(s.options(screens: [imac, lg], hud: false, editable: true).missingScreen)
    }
}

final class AfterSessionTests: XCTestCase {
    private func action(streamed: Bool = true, relinking: Bool = false, stoppedHere: Bool = false,
                        request: ReceiverPower? = nil, onDisconnect: ReceiverSettings.OnDisconnect = .showDesktop) -> AfterSession {
        AfterSession.action(streamed: streamed, relinking: relinking, stoppedHere: stoppedHere, request: request, onDisconnect: onDisconnect)
    }

    func testTheSendersRequestOutranksTheDisplaySetting() {
        XCTAssertEqual(action(request: .shutDown, onDisconnect: .sleepDisplay), .shutDown)
        XCTAssertEqual(action(request: .sleep), .sleep)
        XCTAssertEqual(action(request: .keepOn, onDisconnect: .sleepDisplay), .sleepDisplay)
        XCTAssertEqual(action(onDisconnect: .sleepDisplay), .sleepDisplay)
        XCTAssertEqual(action(), .nothing)
    }

    func testOnlyAStreamThatEndedForGoodPowersDown() {
        XCTAssertEqual(action(streamed: false, request: .shutDown, onDisconnect: .sleepDisplay), .nothing, "early failures retry")
        XCTAssertEqual(action(relinking: true, request: .shutDown, onDisconnect: .sleepDisplay), .nothing, "the sender comes right back")
        XCTAssertEqual(action(stoppedHere: true, request: .shutDown, onDisconnect: .sleepDisplay), .nothing, "stopped on this Mac: desktop stays")
    }
}
