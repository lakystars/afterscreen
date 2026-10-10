import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

/// Panel brightness: private DisplayServices, else IOKit
/// Receiver sets its main panel; sender reads its built-in one
/// Level: the slider's position; linear: share of peak luminance
/// Panels map the slider differently; linear compares across them
public enum PanelBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = services.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter = services.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    private static let linearGetter = services.flatMap { dlsym($0, "DisplayServicesGetLinearBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let linearSetter = services.flatMap { dlsym($0, "DisplayServicesSetLinearBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    /// Main display, 0…1; nil when unreadable
    public static var level: Double? {
        var value: Float = 0
        if let get = getter, get(CGMainDisplayID(), &value) == 0 { return Double(value) }
        return firstDisplay { service in
            var v: Float = 0
            return IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &v) == kIOReturnSuccess ? Double(v) : nil
        }
    }

    /// Built-in panel's level and linear, about 100 µs a read
    /// nil on desktops or with the lid closed
    /// Online, not active: a mirror slave still reads
    public static var builtIn: (level: Double, linear: Double)? {
        guard let get = getter, let getLinear = linearGetter, let id = builtInID else { return nil }
        var level: Float = 0, linear: Float = 0
        guard get(id, &level) == 0, getLinear(id, &linear) == 0 else { return nil }
        return (Double(level), Double(linear))
    }

    /// Built-in panel's peak in nits: its linear 1.0
    /// XDR laptops: the brightness controller's aurora-maximum-nits
    /// Others: measured like the receiver's
    /// Read once; nil when the Mac reports neither
    public static let builtInPeakNits: Double? = {
        let root = IORegistryGetRootEntry(0)
        defer { IOObjectRelease(root) }
        if let data = IORegistryEntrySearchCFProperty(root, kIOServicePlane, "aurora-maximum-nits" as CFString, kCFAllocatorDefault,
                                                      IOOptionBits(kIORegistryIterateRecursively)) as? Data, data.count == 4 {
            let nits = Double(Float(bitPattern: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian))
            if nits.isFinite, nits > 0 { return nits }
        }
        return builtInID.flatMap(measuredPeakNits)
    }()

    /// Peak from CoreDisplay's current nits over the linear level
    /// Non-EDR panels report their light; XDR reports a fixed 100
    /// nil while too dim to divide, or without the calls
    public static func measuredPeakNits(_ display: CGDirectDisplayID) -> Double? {
        guard let nominal = nominalNits, let getLinear = linearGetter else { return nil }
        var linear: Float = 0
        guard getLinear(display, &linear) == 0, linear >= 0.05 else { return nil }
        let peak = Double(nominal(display)) / Double(linear)
        return peak.isFinite && peak > 0 ? peak : nil
    }

    /// Main panel to `nits` given its `peak`
    /// Linear is a share of peak; sliders differ per panel
    /// Without the linear call: the slider, as the closest stand-in
    public static func set(nits: Double, peak: Double) {
        let linear = min(1, max(0, nits / peak))
        if let set = linearSetter, set(CGMainDisplayID(), Float(linear)) == 0 { return }
        self.set(linear)
    }

    private typealias Nominal = @convention(c) (CGDirectDisplayID) -> Float
    private static let nominalNits = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        .flatMap { dlsym($0, "CoreDisplay_Display_GetNominalPixelNits") }.map { unsafeBitCast($0, to: Nominal.self) }

    private static var builtInID: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    public static func set(_ level: Double) {
        if let set = setter, set(CGMainDisplayID(), Float(level)) == 0 { return }
        _ = firstDisplay { service in
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(level)) == kIOReturnSuccess ? level : nil
        }
    }

    /// First display service for which `body` succeeds
    private static func firstDisplay(_ body: (io_service_t) -> Double?) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let result = body(service)
            IOObjectRelease(service)
            if let result = result { return result }
        }
        return nil
    }
}
