import CoreGraphics

public enum RenderGeometry {
    /// Largest rect with the content's aspect ratio, centered in bounds
    public static func aspectFit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
