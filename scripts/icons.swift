// App icon of both apps, drawn in code
// Usage: swift scripts/icons.swift <out-dir>
// Writes AppIcon.iconset; iconutil makes the .icns
import AppKit
import SwiftUI

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, 1])!
}

/// Menu bar glyph on a flat tile
/// Flat fills keep the .icns near 100 KB
func icon(pixels: Int) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // Apple's macOS template: 824 body on a 1024 grid
    c.addPath(RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath)
    c.setFillColor(color(0x3D3BB0))
    c.fillPath()
    // StatusIcon's 20 × 17 pt geometry at 28×, centred
    c.translateBy(x: 512 - 10 * 28, y: 512 - 8.5 * 28)
    c.scaleBy(x: 28, y: 28)
    c.setFillColor(color(0xFFFFFF))
    c.setStrokeColor(color(0xFFFFFF))
    c.setLineWidth(1.5)
    c.addPath(CGPath(roundedRect: CGRect(x: 0.75, y: 3.25, width: 18.5, height: 13), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
    c.strokePath()
    c.fill(CGRect(x: 9, y: 1.5, width: 2, height: 1.75))
    c.addPath(CGPath(roundedRect: CGRect(x: 6, y: 0.25, width: 8, height: 1.5), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
    c.fillPath()
    // Own bolt: SF Symbols are barred from app icons
    let h: CGFloat = 8.5, w: CGFloat = 5.6, x0 = 10 - w / 2, y0 = 9.75 - h / 2
    let corners: [(CGFloat, CGFloat)] = [(0.68, 1), (0.02, 0.42), (0.46, 0.42), (0.32, 0), (0.98, 0.58), (0.54, 0.58)]
    let bolt = CGMutablePath()
    bolt.addLines(between: corners.map { CGPoint(x: x0 + $0.0 * w, y: y0 + $0.1 * h) })
    bolt.closeSubpath()
    c.addPath(bolt)
    // Round joins soften the tips
    c.setLineJoin(.round)
    c.setLineWidth(0.5)
    c.drawPath(using: .fillStroke)
    return c.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".").appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = NSBitmapImageRep(cgImage: icon(pixels: points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: out.appendingPathComponent("icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"))
    }
}
