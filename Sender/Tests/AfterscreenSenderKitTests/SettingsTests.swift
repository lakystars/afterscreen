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
    }
}

final class AutoConnectTests: XCTestCase {
    private func receiver(_ name: String) -> DiscoveredReceiver {
        DiscoveredReceiver(name: name, model: "", panel: "", port: 1, addresses: ["192.168.1.2"])
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
