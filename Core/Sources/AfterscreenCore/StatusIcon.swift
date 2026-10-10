import AppKit

/// Menu bar icon of both apps: a display outline with the link's symbol in its screen, one size for every link.
/// Drawn rather than the "display" symbol, whose stand leaves too short a screen for a readable mark
@available(macOS 11, *)
public enum StatusIcon {
    static let size = NSSize(width: 20, height: 17)
    /// Screen outline path; the stroke straddles it
    static let screen = NSRect(x: 0.75, y: 3.25, width: 18.5, height: 13)
    static let bezel: CGFloat = 0.75
    /// Mark ink, not the symbol's padded image: 8.5 pt tall unless wider than 13 pt
    static let markHeight: CGFloat = 8.5
    static let markWidth: CGFloat = 13

    private static let lock = NSLock()
    private static var symbols: [String: (image: NSImage, ink: NSRect)] = [:]
    private static var icons: [LinkKind?: NSImage] = [:]

    /// One image per link, so an unchanged link hands the status button the same object
    public static func image(link: LinkKind?) -> NSImage {
        lock.lock()
        let cached = icons[link]
        lock.unlock()
        if let cached = cached { return cached }
        let made = draw(link: link)
        lock.lock()
        defer { lock.unlock() }
        if let raced = icons[link] { return raced }
        icons[link] = made
        return made
    }

    private static func draw(link: LinkKind?) -> NSImage {
        let mark = LinkLabel.symbol(link).map { symbol($0) }
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = bezel * 2
            outline.stroke()
            NSBezierPath(rect: NSRect(x: 9, y: 1.5, width: 2, height: 1.75)).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 0.25, width: 8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            if let mark = mark { mark.image.draw(in: destination(mark)) }
            return true
        }
        image.isTemplate = true
        return image
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

    /// Image rect that centres the ink in the screen, on half points so it stays sharp at 2x
    private static func destination(_ mark: (image: NSImage, ink: NSRect)) -> NSRect {
        let k = scale(mark.ink)
        let inkSize = NSSize(width: mark.ink.width * k, height: mark.ink.height * k)
        let x = ((screen.midX - inkSize.width / 2) * 2).rounded() / 2
        let y = ((screen.midY - inkSize.height / 2) * 2).rounded() / 2
        return NSRect(x: x - mark.ink.minX * k, y: y - mark.ink.minY * k,
                      width: mark.image.size.width * k, height: mark.image.size.height * k)
    }

    /// The symbol at 20 pt and its ink bounds, measured once
    private static func symbol(_ name: String) -> (image: NSImage, ink: NSRect) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = symbols[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        let entry = (image, inkBounds(image))
        symbols[name] = entry
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
