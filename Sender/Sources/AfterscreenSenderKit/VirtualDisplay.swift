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
public final class VirtualDisplay {
    public let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    /// `streamPixels` is the backing size; HiDPI when it is twice `points`
    public init(name: String, streamPixels: PixelSize, points: PixelSize, refresh: Double = 60) throws {
        let hiDPI = streamPixels.width >= points.width * 2
        let desc = CGVirtualDisplayDescriptor()
        desc.name = name
        desc.maxPixelsWide = UInt32(streamPixels.width)
        desc.maxPixelsHigh = UInt32(streamPixels.height)
        // 27" class panel; macOS uses it only for physical size hints
        desc.sizeInMillimeters = CGSize(width: 597, height: 336)
        desc.vendorID = 0x5056
        desc.productID = 0x4C4B
        desc.serialNum = UInt32(truncatingIfNeeded: streamPixels.width &* 31 &+ streamPixels.height)
        desc.queue = DispatchQueue.main
        guard let display = CGVirtualDisplay(descriptor: desc) else { throw VirtualDisplayError.create }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(points.width), height: UInt(points.height), refreshRate: refresh)]
        guard display.apply(settings) else { throw VirtualDisplayError.settings }
        self.display = display
        displayID = display.displayID
        try activateMode(streamPixels: streamPixels, points: points)
    }

    /// Lists modes including duplicate low-resolution ones, then applies the backing-size match
    private func activateMode(streamPixels: PixelSize, points: PixelSize) throws {
        let deadline = Date().addingTimeInterval(3)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        while Date() < deadline {
            let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
            let infos = modes.map { ModeInfo(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth,
                                             pixelHeight: $0.pixelHeight, refreshRate: $0.refreshRate) }
            if let index = VirtualDisplay.pickMode(infos, streamPixels: streamPixels, sourcePoints: points),
               CGDisplaySetDisplayMode(displayID, modes[index], nil) == .success {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw VirtualDisplayError.mode
    }

    /// Exact backing-pixel match (fastest refresh), else the largest backing at the requested points
    public static func pickMode(_ modes: [ModeInfo], streamPixels: PixelSize, sourcePoints: PixelSize) -> Int? {
        let exact = modes.indices.filter {
            modes[$0].pixelWidth == streamPixels.width && modes[$0].pixelHeight == streamPixels.height
        }
        if let best = exact.max(by: { modes[$0].refreshRate < modes[$1].refreshRate }) { return best }
        let atPoints = modes.indices.filter {
            modes[$0].width == sourcePoints.width && modes[$0].height == sourcePoints.height
        }
        return atPoints.max(by: { modes[$0].pixelWidth < modes[$1].pixelWidth })
    }

    public var bounds: CGRect { CGDisplayBounds(displayID) }
}
