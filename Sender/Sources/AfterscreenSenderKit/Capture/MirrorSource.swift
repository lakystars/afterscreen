import CoreGraphics
import AfterscreenCore

/// Display the iMac copies in mirror mode: the main display
/// Captured at backing pixels, no resampling
struct MirrorSource: Equatable {
    let displayID: CGDirectDisplayID
    let pixels: PixelSize
    /// Backing pixels per point
    let scale: Double

    static var main: MirrorSource? {
        let id = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
        let scale = Double(mode.pixelWidth) / Double(mode.width)
        return MirrorSource(displayID: id, pixels: pixels(bounds: CGDisplayBounds(id).size, scale: scale), scale: scale)
    }

    /// Bounds follow rotation; the pixel scale does not
    static func pixels(bounds: CGSize, scale: Double) -> PixelSize {
        PixelSize(width: Int((Double(bounds.width) * scale).rounded()), height: Int((Double(bounds.height) * scale).rounded()))
    }

    /// Display points shown in `stream`, anchored top left
    /// The stream's exact shape: capture never letterboxes inside it
    /// Alignment-only trims stay 1:1, dropping up to 3 edge pixels
    func region(for stream: PixelSize) -> CGRect {
        guard scale > 0, stream.width > 0, stream.height > 0 else { return .zero }
        let k = min(Double(pixels.width) / Double(stream.width), Double(pixels.height) / Double(stream.height))
        return CGRect(x: 0, y: 0, width: Double(stream.width) * k / scale, height: Double(stream.height) * k / scale)
    }
}
