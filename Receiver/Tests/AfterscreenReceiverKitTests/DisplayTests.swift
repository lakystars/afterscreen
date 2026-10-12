import XCTest
import AfterscreenCore
@testable import AfterscreenReceiverKit

final class DisplayChoiceTests: XCTestCase {
    private func display(_ key: String, builtIn: Bool = false, main: Bool = false) -> ReceiverDisplay {
        ReceiverDisplay(id: CGDirectDisplayID(key.hashValue & 0xffff), key: key, name: key, pixels: PixelSize(width: 2560, height: 1440),
                        builtIn: builtIn, main: main)
    }

    func testTheChosenScreenWinsWhileConnected() {
        let screens = [display("lcd", builtIn: true, main: true), display("lg"), display("zeus")]
        XCTAssertEqual(DisplayChoice.pick(screens, saved: "zeus")?.key, "zeus")
    }

    func testAutomaticPrefersThePanelOfThisMac() {
        // A MacBook with its menu bar on a monitor
        let screens = [display("lg", main: true), display("lcd", builtIn: true)]
        XCTAssertEqual(DisplayChoice.pick(screens, saved: nil)?.key, "lcd")
        XCTAssertEqual(DisplayChoice.pick(screens, saved: "gone")?.key, "lcd", "a chosen screen unplugged falls back")
    }

    func testWithoutAPanelTheMenuBarScreen() {
        // Mac mini, or a MacBook closed in clamshell mode
        let screens = [display("zeus"), display("lg", main: true)]
        XCTAssertEqual(DisplayChoice.pick(screens, saved: nil)?.key, "lg")
        XCTAssertNil(DisplayChoice.pick([], saved: nil))
    }
}

final class NotchTests: XCTestCase {
    func testTheStreamFitsBelowTheNotch() {
        let panel = PixelSize(width: 3024, height: 1964)
        // 14-inch at More Space and at Default: same pixels
        // Its full-screen window measured 949 of 982 points
        XCTAssertEqual(HardwareInfo.belowNotch(panel, screenHeight: 1169, safeTop: 38), PixelSize(width: 3024, height: 1896))
        XCTAssertEqual(HardwareInfo.belowNotch(panel, screenHeight: 982, safeTop: 32), PixelSize(width: 3024, height: 1896))
    }

    func testHeightsStayMultiplesOfFour() {
        let below = HardwareInfo.belowNotch(PixelSize(width: 3456, height: 2234), screenHeight: 1117, safeTop: 36)
        XCTAssertEqual(below.width, 3456)
        XCTAssertEqual(below.height % 4, 0)
        XCTAssertLessThanOrEqual(below.height, 2234 - 74)
    }

    func testPanelsWithoutANotchKeepTheirSize() {
        let imac = PixelSize(width: 5120, height: 2880)
        XCTAssertEqual(HardwareInfo.belowNotch(imac, screenHeight: 1440, safeTop: 0), imac)
    }
}

final class PlacementTests: XCTestCase {
    func testANearFitDrawsOneToOne() {
        // Window a few pixels taller: no resampling
        let r = RenderGeometry.aspectFit(content: CGSize(width: 3024, height: 1900), in: CGRect(x: 0, y: 0, width: 3024, height: 1903))
        XCTAssertEqual(r, CGRect(x: 0, y: 1, width: 3024, height: 1900))
        let near = RenderGeometry.aspectFit(content: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 1005, height: 505))
        XCTAssertEqual(near, CGRect(x: 2, y: 2, width: 1000, height: 500))
    }

    func testRealScalingStays() {
        // A four-fifths stream still fills the screen
        let r = RenderGeometry.aspectFit(content: CGSize(width: 2416, height: 1520), in: CGRect(x: 0, y: 0, width: 3020, height: 1900))
        XCTAssertEqual(r.width, 3020, accuracy: 0.01)
        XCTAssertEqual(r.height, 1900, accuracy: 0.01)
    }
}

final class PanelModeTests: XCTestCase {
    private let panel = PixelSize(width: 3024, height: 1964)
    private let moreSpace = DisplayModeInfo(width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338, isNative: false)
    private let standard = DisplayModeInfo(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, isNative: false)
    private let native = DisplayModeInfo(width: 3024, height: 1964, pixelWidth: 3024, pixelHeight: 1964, isNative: true)

    func testAScaledModeSwitchesToThePanelsHiDPIMode() {
        let modes = [moreSpace, native, standard]
        XCTAssertEqual(PanelMode.nativeMode(modes, panel: panel, current: moreSpace), 2)
    }

    func testModesDrawingThePanelOneToOneStay() {
        let modes = [moreSpace, native, standard]
        XCTAssertNil(PanelMode.nativeMode(modes, panel: panel, current: standard))
        XCTAssertNil(PanelMode.nativeMode(modes, panel: panel, current: native))
    }

    func testOneToOneWhenThereIsNoHiDPIMode() {
        let low = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, isNative: false)
        let full = DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, isNative: true)
        XCTAssertEqual(PanelMode.nativeMode([low, full], panel: PixelSize(width: 2560, height: 1440), current: low), 1)
        XCTAssertNil(PanelMode.nativeMode([low], panel: PixelSize(width: 2560, height: 1440), current: low), "no mode draws the panel")
    }
}
