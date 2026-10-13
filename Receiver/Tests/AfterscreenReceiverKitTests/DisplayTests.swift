import Metal
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

final class GPUChoiceTests: XCTestCase {
    private let integrated = GPUChoice.GPU(id: 1, lowPower: true, headless: false, removable: false)
    private let discrete = GPUChoice.GPU(id: 2, lowPower: false, headless: false, removable: false)

    func testOnlyATwoGPUMacBookProSwitches() {
        XCTAssertTrue(GPUChoice.switching([discrete, integrated], model: "MacBookPro11,5"))
        XCTAssertFalse(GPUChoice.switching([integrated], model: "MacBookPro12,1"))
        // Apple silicon: one GPU, not low power
        XCTAssertFalse(GPUChoice.switching([discrete], model: "MacBookPro18,3"))
        // iMac: the integrated GPU only decodes video
        let decoder = GPUChoice.GPU(id: 1, lowPower: true, headless: true, removable: false)
        XCTAssertFalse(GPUChoice.switching([discrete, decoder], model: "MacBookPro16,1"))
        XCTAssertFalse(GPUChoice.switching([discrete, integrated], model: "iMac18,3"))
    }

    func testItStreamsItsPanelOnTheDiscreteGPUOnly() {
        // Either GPU may drive the panel when the session starts
        let gpus = [discrete, integrated]
        let streaming = GPUChoice.preference(switching: true, builtIn: true, streaming: true)
        let idle = GPUChoice.preference(switching: true, builtIn: true, streaming: false)
        XCTAssertEqual(GPUChoice.pick(gpus, driving: 1, prefer: streaming), 2)
        XCTAssertEqual(GPUChoice.pick(gpus, driving: 2, prefer: idle), 1)
    }

    func testItsMonitorStreamsOnTheGPUDrivingIt() {
        let kind = GPUChoice.preference(switching: true, builtIn: false, streaming: true)
        XCTAssertNil(kind)
        XCTAssertEqual(GPUChoice.pick([discrete, integrated], driving: 2, prefer: kind), 2)
        XCTAssertEqual(GPUChoice.preference(switching: true, builtIn: false, streaming: false), .integrated,
                       "idle: never holds the discrete GPU")
    }

    func testOtherMacsDrawOnTheGPUDrivingTheirScreen() {
        XCTAssertNil(GPUChoice.preference(switching: false, builtIn: true, streaming: true))
        // Mac Pro with two cards; a monitor on an eGPU
        let second = GPUChoice.GPU(id: 3, lowPower: false, headless: false, removable: false)
        let egpu = GPUChoice.GPU(id: 4, lowPower: false, headless: false, removable: true)
        XCTAssertEqual(GPUChoice.pick([discrete, second], driving: 3, prefer: nil), 3)
        XCTAssertEqual(GPUChoice.pick([integrated, egpu], driving: 4, prefer: nil), 4)
    }

    func testNoDrivingGPULeavesTheSystemDefault() {
        XCTAssertNil(GPUChoice.pick([discrete], driving: nil, prefer: nil))
        XCTAssertNil(GPUChoice.pick([discrete], driving: 9, prefer: nil))
    }

    func testOneGPUMacsKeepIt() throws {
        let system = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(MTLCopyAllDevices().count == 1, "one GPU")
        XCTAssertNil(GPUChoice.kind(for: CGMainDisplayID(), streaming: true))
        XCTAssertEqual(GPUChoice.device(for: CGMainDisplayID(), streaming: false)?.registryID, system.registryID)
        XCTAssertEqual(GPUChoice.device(for: CGMainDisplayID(), streaming: true)?.registryID, system.registryID)
    }

    func testTheSameGPUKeepsTheRenderer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(StreamRenderer(device: device))
        XCTAssertTrue(renderer.use(device))
        XCTAssertEqual(renderer.deviceID, device.registryID)
        XCTAssertTrue(renderer.layer.device === device)
    }

    func testTheDiscreteRequestIsHeldUntilReleased() {
        let request = DiscreteGPURequest()
        request.hold()
        XCTAssertTrue(request.isHeld, "OpenGL found and a pixel format made")
        request.hold()
        request.release()
        XCTAssertFalse(request.isHeld)
        request.release()
    }
}
