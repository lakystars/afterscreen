import CoreGraphics

public enum RenderGeometry {
    /// Upscales under this are drawn 1:1 instead
    /// A window a few pixels taller would resample every frame
    static let snap: CGFloat = 1.01

    /// Largest rect with the content's aspect ratio, centered in bounds
    /// Whole-unit origin when drawn 1:1: pixels land on pixels
    public static func aspectFit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var scale = min(bounds.width / content.width, bounds.height / content.height)
        let exact = scale >= 1 && scale < snap
        if exact { scale = 1 }
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        var x = bounds.minX + (bounds.width - size.width) / 2, y = bounds.minY + (bounds.height - size.height) / 2
        if exact { (x, y) = (x.rounded(.down), y.rounded(.down)) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
