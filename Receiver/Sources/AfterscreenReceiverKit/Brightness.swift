import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

/// Built-in panel brightness: DisplayServices (private, loaded at run time), else IOKit display parameters
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = services.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter = services.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    static var level: Double? {
        var value: Float = 0
        if let get = getter, get(CGMainDisplayID(), &value) == 0 { return Double(value) }
        return firstDisplay { service in
            var v: Float = 0
            return IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &v) == kIOReturnSuccess ? Double(v) : nil
        }
    }

    static func set(_ level: Double) {
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
