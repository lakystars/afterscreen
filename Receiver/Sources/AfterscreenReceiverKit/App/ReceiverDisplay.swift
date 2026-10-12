import AppKit
import AfterscreenCore

/// A connected screen the stream can show on
public struct ReceiverDisplay: Equatable {
    public var id: CGDirectDisplayID
    /// Vendor, model and serial: same screen after replugging
    public var key: String
    public var name: String
    /// Native panel pixels
    public var pixels: PixelSize
    public var builtIn: Bool
    /// Holds the menu bar
    public var main: Bool

    /// Screens in System Settings' order
    public static func connected() -> [ReceiverDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return ReceiverDisplay(id: id, key: key(of: id), name: screen.localizedName, pixels: HardwareInfo.panelPixels(id),
                                   builtIn: CGDisplayIsBuiltin(id) != 0, main: id == CGMainDisplayID())
        }
    }

    /// Twin monitors without serials told apart by unit
    static func key(of id: CGDirectDisplayID) -> String {
        let serial = CGDisplaySerialNumber(id)
        let base = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))"
        return serial != 0 ? "\(base)-\(serial)" : "\(base)-u\(CGDisplayUnitNumber(id))"
    }

    public var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }
}

public enum DisplayChoice {
    /// The chosen screen while connected
    /// Else this Mac's own panel, else the menu bar's screen
    public static func pick(_ displays: [ReceiverDisplay], saved: String?) -> ReceiverDisplay? {
        if let key = saved, let chosen = displays.first(where: { $0.key == key }) { return chosen }
        return displays.first(where: \.builtIn) ?? displays.first(where: \.main) ?? displays.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
