import CoreGraphics
import Foundation
import AfterscreenCore
import PrivateAPI

public struct ModeInfo: Equatable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
}

public enum VirtualDisplayError: Error, CustomStringConvertible {
    case create
    case settings
    case mode

    public var description: String {
        switch self {
        case .create: return "macOS refused to create the virtual display"
        case .settings: return "macOS rejected the virtual display modes"
        case .mode: return "No display mode matches the receiver panel"
        }
    }
}

/// Extended display backed by CGVirtualDisplay; removed when released
/// Registers every "looks like" size, also listed in Displays settings
public final class VirtualDisplay {
    public let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay
    private let hiDPI: Bool

    /// `modes` in points; HiDPI backing is 2× the points
    public init(name: String, streamPixels: PixelSize, hiDPI: Bool, modes: [PixelSize], initial: PixelSize, refresh: Double = 60) throws {
        let scale = hiDPI ? 2 : 1
        let desc = CGVirtualDisplayDescriptor()
        desc.name = name
        desc.maxPixelsWide = UInt32(max(streamPixels.width, (modes.map(\.width).max() ?? 0) * scale))
        desc.maxPixelsHigh = UInt32(max(streamPixels.height, (modes.map(\.height).max() ?? 0) * scale))
        // 27" panel; macOS uses it only for physical size hints
        desc.sizeInMillimeters = CGSize(width: 597, height: 336)
        desc.vendorID = 0x5056
        desc.productID = 0x4C4B
        desc.serialNum = UInt32(truncatingIfNeeded: streamPixels.width &* 31 &+ streamPixels.height)
        desc.queue = DispatchQueue.main
        guard let display = CGVirtualDisplay(descriptor: desc) else { throw VirtualDisplayError.create }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = modes.map { CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: refresh) }
        guard display.apply(settings) else { throw VirtualDisplayError.settings }
        self.display = display
        self.hiDPI = hiDPI
        displayID = display.displayID
        // The mode list appears shortly after the settings apply
        let deadline = Date().addingTimeInterval(3)
        while !setMode(points: initial) {
            guard Date() < deadline else { throw VirtualDisplayError.mode }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Sets "looks like" size; false if no such mode listed
    @discardableResult
    public func setMode(points: PixelSize) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        let infos = modes.map { ModeInfo(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth,
                                         pixelHeight: $0.pixelHeight, refreshRate: $0.refreshRate) }
        guard let index = VirtualDisplay.pickMode(infos, points: points, hiDPI: hiDPI) else { return false }
        return CGDisplaySetDisplayMode(displayID, modes[index], nil) == .success
    }

    /// Mode at `points` with full backing (2× when HiDPI)
    /// Prefers fastest refresh; else largest backing at those points
    /// List must include duplicate low-resolution modes
    /// macOS lists a HiDPI size's 1x variant first
    public static func pickMode(_ modes: [ModeInfo], points: PixelSize, hiDPI: Bool) -> Int? {
        let atPoints = modes.indices.filter { modes[$0].width == points.width && modes[$0].height == points.height }
        let exact = atPoints.filter { modes[$0].pixelWidth == points.width * (hiDPI ? 2 : 1) }
        if let best = exact.max(by: { modes[$0].refreshRate < modes[$1].refreshRate }) { return best }
        return atPoints.max(by: { modes[$0].pixelWidth < modes[$1].pixelWidth })
    }

    public var bounds: CGRect { CGDisplayBounds(displayID) }
}
