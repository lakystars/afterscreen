import AppKit

/// Menu bar icon of both apps
/// Display outline with the link symbol in its screen
/// Corner badge tells the apps apart: arrow out or in
/// Same size for every link
/// Custom-drawn: SF "display" stand leaves the mark too little room
@available(macOS 11, *)
public enum StatusIcon {
    public enum Role { case sender, receiver }

    static let size = NSSize(width: 20, height: 17)
    /// Screen outline path; the stroke straddles it
    static let screen = NSRect(x: 0.75, y: 3.25, width: 18.5, height: 13)
    static let bezel: CGFloat = 0.75
    /// Mark ink size, not the symbol's padded image
    /// 8.5 pt tall unless wider than 13 pt
    static let markHeight: CGFloat = 8.5
    static let markWidth: CGFloat = 13
    /// Disc touching the bezel's outer top and right edges
    static let badgeRadius: CGFloat = 3.75
    /// Cleared around the disc: cuts the bezel and the mark
    static let badgeGap: CGFloat = 1.25
    /// Arrow ink knocked out of the disc
    static let arrowHeight: CGFloat = 4.2
    static var badgeCentre: NSPoint {
        NSPoint(x: screen.maxX + bezel - badgeRadius, y: screen.maxY + bezel - badgeRadius)
    }

    private struct Key: Hashable {
        let link: LinkKind?
        let role: Role
    }

    private static let lock = NSLock()
    private static var symbols: [String: (image: NSImage, ink: NSRect)] = [:]
    private static var icons: [Key: NSImage] = [:]

    /// One image per link and role
    /// Unchanged link hands the status button the same object
    public static func image(link: LinkKind?, role: Role) -> NSImage {
        let key = Key(link: link, role: role)
        lock.lock()
        let cached = icons[key]
        lock.unlock()
        if let cached = cached { return cached }
        let made = draw(link: link, role: role)
        lock.lock()
        defer { lock.unlock() }
        if let raced = icons[key] { return raced }
        icons[key] = made
        return made
    }

    private static func draw(link: LinkKind?, role: Role) -> NSImage {
        let mark = LinkLabel.symbol(link).map { symbol($0) }
        let arrow = symbol(role == .sender ? "arrow.up.right" : "arrow.down.left", weight: .heavy)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = bezel * 2
            outline.stroke()
            NSBezierPath(rect: NSRect(x: 9, y: 1.5, width: 2, height: 1.75)).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 0.25, width: 8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            if let mark = mark { mark.image.draw(in: destination(mark)) }
            badge(arrow)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Gap cleared, disc filled, arrow knocked out of it
    private static func badge(_ arrow: (image: NSImage, ink: NSRect)) {
        let c = badgeCentre, r = badgeRadius, g = badgeRadius + badgeGap
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: c.x - g, y: c.y - g, width: g * 2, height: g * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        let k = arrowHeight / max(arrow.ink.height, 0.1)
        let rect = NSRect(x: c.x - arrow.ink.midX * k, y: c.y - arrow.ink.midY * k,
                          width: arrow.image.size.width * k, height: arrow.image.size.height * k)
        arrow.image.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
    }

    /// Where the mark's ink lands in the icon
    static func markInk(_ link: LinkKind) -> NSRect {
        guard let name = LinkLabel.symbol(link) else { return .zero }
        let mark = symbol(name)
        let k = scale(mark.ink)
        let d = destination(mark)
        return NSRect(x: d.minX + mark.ink.minX * k, y: d.minY + mark.ink.minY * k, width: mark.ink.width * k, height: mark.ink.height * k)
    }

    private static func scale(_ ink: NSRect) -> CGFloat {
        min(markHeight / max(ink.height, 0.1), markWidth / max(ink.width, 0.1))
    }

    /// Image rect centring the ink in the screen
    /// Snapped to half points: sharp at 2x
    private static func destination(_ mark: (image: NSImage, ink: NSRect)) -> NSRect {
        let k = scale(mark.ink)
        let inkSize = NSSize(width: mark.ink.width * k, height: mark.ink.height * k)
        let x = ((screen.midX - inkSize.width / 2) * 2).rounded() / 2
        let y = ((screen.midY - inkSize.height / 2) * 2).rounded() / 2
        return NSRect(x: x - mark.ink.minX * k, y: y - mark.ink.minY * k,
                      width: mark.image.size.width * k, height: mark.image.size.height * k)
    }

    /// Symbol at 20 pt and its ink bounds, measured once
    private static func symbol(_ name: String, weight: NSFont.Weight = .bold) -> (image: NSImage, ink: NSRect) {
        let key = "\(name) \(weight.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = symbols[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        let entry = (image, inkBounds(image))
        symbols[key] = entry
        return entry
    }

    /// Opaque bounds in points, origin bottom left, found at 4x
    private static func inkBounds(_ image: NSImage) -> NSRect {
        let s: CGFloat = 4
        let w = Int(image.size.width * s), h = Int(image.size.height * s)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let bytes = rep.bitmapData else { return NSRect(origin: .zero, size: image.size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where bytes[y * w * 4 + x * 4 + 3] > 25 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return NSRect(origin: .zero, size: image.size) }
        // Bitmap rows run top down
        return NSRect(x: CGFloat(minX) / s, y: image.size.height - CGFloat(maxY + 1) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }
}
