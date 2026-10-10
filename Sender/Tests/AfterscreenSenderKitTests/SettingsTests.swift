import AfterscreenCore
import XCTest
@testable import AfterscreenSenderKit

final class DisplaySizeTests: XCTestCase {
    func testFiveKSizesMatchMacOSScaledModes() {
        let points = PixelSize(width: 2560, height: 1440)
        XCTAssertEqual(DisplaySize.allCases.map { $0.points(for: points) },
                       [PixelSize(width: 2048, height: 1152), PixelSize(width: 2560, height: 1440),
                        PixelSize(width: 2880, height: 1620), PixelSize(width: 3200, height: 1800)])
    }

    func testFourKSizes() {
        let points = PixelSize(width: 2048, height: 1152)
        XCTAssertEqual(DisplaySize.allCases.map { $0.points(for: points) },
                       [PixelSize(width: 1600, height: 900), PixelSize(width: 2048, height: 1152),
                        PixelSize(width: 2304, height: 1296), PixelSize(width: 2560, height: 1440)])
    }
}

final class StatusTitleTests: XCTestCase {
    private let figure = "\u{2007}"

    func testThroughputKeepsFourCharactersSoTheMenuBarItemHoldsItsWidth() {
        XCTAssertEqual(Format.compactGbps(3.2e9), "3.2G")
        XCTAssertEqual(Format.compactGbps(329e6), "329M")
        XCTAssertEqual(Format.compactGbps(33e6), figure + "33M")
        XCTAssertEqual(Format.compactGbps(5e6), figure + figure + "5M")
        XCTAssertEqual(Format.compactGbps(12.5e9), figure + "12G")
    }

    func testIconOnlyUnlessStatsAreOn() {
        var s = SenderSnapshot()
        s.link = .usb
        XCTAssertEqual(StatusTitle.text(s, stats: true), "")
        XCTAssertNil(StatusTitle.mark(s), "no link mark until streaming")
        s.isStreaming = true
        s.sentFPS = 9
        s.throughputBitsPerSecond = 33e6
        XCTAssertEqual(StatusTitle.mark(s), .usb)
        XCTAssertEqual(StatusTitle.text(s, stats: false), "")
        XCTAssertEqual(StatusTitle.text(s, stats: true), figure + "9fps · " + figure + "33M")
    }
}

final class StatusButtonTests: XCTestCase {
    func testTheButtonIsTouchedOnlyWhenSomethingChanges() {
        // Each assignment lays out the item again, and the popover anchored to it closes its open menus
        let button = NSButton()
        let idle = StatusIcon.image(link: nil)
        XCTAssertTrue(StatusButton.show(button, image: idle, title: ""))
        XCTAssertFalse(StatusButton.show(button, image: StatusIcon.image(link: nil), title: ""))
        XCTAssertTrue(StatusButton.show(button, image: StatusIcon.image(link: .thunderbolt), title: ""))
        XCTAssertTrue(StatusButton.show(button, image: StatusIcon.image(link: .thunderbolt), title: "60fps"))
        XCTAssertFalse(StatusButton.show(button, image: StatusIcon.image(link: .thunderbolt), title: "60fps"))
    }
}

final class PopoverFocusKeeperTests: XCTestCase {
    private let center = NotificationCenter()

    private func keeper(shown: Bool, focused: Bool, restored: @escaping () -> Void) -> PopoverFocusKeeper {
        let k = PopoverFocusKeeper(center: center) { _, check in check() }
        k.isShown = { shown }
        k.isFocused = { focused }
        k.restore = restored
        return k
    }

    func testAnOpenPopoverGetsFocusBackAfterTheDisplaysChange() {
        var restores = 0
        let k = keeper(shown: true, focused: false) { restores += 1 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertGreaterThan(restores, 0)
        withExtendedLifetime(k) {}
    }

    func testFocusIsLeftAloneWhenClosedOrStillFocused() {
        var restores = 0
        let closed = keeper(shown: false, focused: false) { restores += 1 }
        let focused = keeper(shown: true, focused: true) { restores += 1 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(restores, 0)
        withExtendedLifetime((closed, focused)) {}
    }
}

final class SenderSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "afterscreen-tests-\(UUID().uuidString)")
    }

    func testDefaultsAndPersistence() {
        let settings = SenderSettings(defaults: defaults)
        XCTAssertEqual(settings.displaySize, .standard)
        XCTAssertTrue(settings.autoConnect)
        XCTAssertNil(settings.lastReceiver)
        settings.displaySize = .more
        settings.autoConnect = false
        settings.lastReceiver = "iMac"
        let again = SenderSettings(defaults: defaults)
        XCTAssertEqual(again.displaySize, .more)
        XCTAssertFalse(again.autoConnect)
        XCTAssertEqual(again.lastReceiver, "iMac")
        XCTAssertNil(again.link, "automatic by default")
        XCTAssertFalse(again.menuBarStats, "icon only by default")
        again.menuBarStats = true
        XCTAssertTrue(SenderSettings(defaults: defaults).menuBarStats)
        again.link = .ethernet
        XCTAssertEqual(SenderSettings(defaults: defaults).link, .ethernet)
        again.link = nil
        XCTAssertNil(SenderSettings(defaults: defaults).link)
        XCTAssertEqual(again.deband, .normal)
        again.deband = .strong
        XCTAssertEqual(SenderSettings(defaults: defaults).deband, .strong)
        XCTAssertEqual(again.brightness, 1, "full brightness until the slider moves")
        XCTAssertEqual(again.streamResolution, .auto)
        again.streamResolution = .reduced
        XCTAssertEqual(SenderSettings(defaults: defaults).streamResolution, .reduced)
        again.brightness = 0.4
        XCTAssertEqual(SenderSettings(defaults: defaults).brightness, 0.4, accuracy: 1e-9)
        XCTAssertEqual(again.displayRole, .extend)
        again.displayRole = .mirror
        XCTAssertEqual(SenderSettings(defaults: defaults).displayRole, .mirror)
        XCTAssertEqual(again.mirrorFit, .mac, "the Mac keeps its resolution unless asked")
        again.mirrorFit = .iMac
        XCTAssertEqual(SenderSettings(defaults: defaults).mirrorFit, .iMac)
    }
}

final class AutoConnectTests: XCTestCase {
    private func receiver(_ name: String) -> DiscoveredReceiver {
        DiscoveredReceiver(name: name, model: "", panel: "", port: 1, host: "", addresses: ["192.168.1.2"])
    }

    func testConnectsToTheLastReceiverWhenItAppears() {
        var rule = AutoConnect()
        XCTAssertNil(rule.target(in: [receiver("iMac")], last: nil, enabled: true))
        XCTAssertEqual(rule.target(in: [receiver("Other"), receiver("iMac")], last: "iMac", enabled: true)?.name, "iMac")
        XCTAssertNil(rule.target(in: [receiver("iMac")], last: "iMac", enabled: false))
        rule.userDisconnected()
        XCTAssertNil(rule.target(in: [receiver("iMac")], last: "iMac", enabled: true), "a Disconnect pauses it")
        XCTAssertNil(rule.target(in: [], last: "iMac", enabled: true))
        XCTAssertEqual(rule.target(in: [receiver("iMac")], last: "iMac", enabled: true)?.name, "iMac", "until the receiver goes away")
    }

    func testRetryBackoffDoublesToAMinuteAndResetsOnStreaming() {
        var rule = AutoConnect()
        XCTAssertEqual((0..<6).map { _ in rule.nextRetryDelay() }, [3, 6, 12, 24, 48, 60])
        rule.streamed()
        XCTAssertEqual(rule.nextRetryDelay(), 3)
    }
}

