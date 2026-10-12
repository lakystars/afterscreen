// App icons of both apps, drawn in code
// Usage: swift scripts/icons.swift <out-dir>
// Writes Sender.iconset and Receiver.iconset; iconutil makes the .icns
import AppKit
import SwiftUI

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, 1])!
}

enum Role: String, CaseIterable { case sender = "Sender", receiver = "Receiver" }

/// Menu bar glyph on a flat tile
/// Flat fills keep the .icns near 100 KB
func icon(pixels: Int, role: Role) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    // Apple's macOS template: 824 body on a 1024 grid
    c.addPath(RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath)
    let tile = color(0x3D3BB0), white = color(0xFFFFFF)
    c.setFillColor(tile)
    c.fillPath()
    // StatusIcon's 20 × 17 pt geometry at 28×, centred
    c.translateBy(x: 512 - 10 * 28, y: 512 - 8.5 * 28)
    c.scaleBy(x: 28, y: 28)
    c.setFillColor(white)
    c.setStrokeColor(white)
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
    // StatusIcon's corner badge; gap painted in the tile colour
    let r: CGFloat = 3.75, gap: CGFloat = r + 1.25, centre = CGPoint(x: 20 - r, y: 17 - r)
    c.setFillColor(tile)
    c.fillEllipse(in: CGRect(x: centre.x - gap, y: centre.y - gap, width: gap * 2, height: gap * 2))
    c.setFillColor(white)
    c.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    // Own arrow: 4.2 pt ink like the menu bar's
    let d: CGFloat = role == .sender ? 1 : -1, reach: CGFloat = 1.7, head: CGFloat = 2.3
    let tip = CGPoint(x: centre.x + reach * d, y: centre.y + reach * d)
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: centre.x - reach * d, y: centre.y - reach * d))
    arrow.addLine(to: tip)
    arrow.move(to: CGPoint(x: tip.x - head * d, y: tip.y))
    arrow.addLine(to: tip)
    arrow.addLine(to: CGPoint(x: tip.x, y: tip.y - head * d))
    c.addPath(arrow)
    c.setStrokeColor(tile)
    c.setLineWidth(0.8)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.strokePath()
    return c.makeImage()!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for role in Role.allCases {
    let out = dir.appendingPathComponent(role.rawValue + ".iconset")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let png = NSBitmapImageRep(cgImage: icon(pixels: points * scale, role: role)).representation(using: .png, properties: [:])!
            try png.write(to: out.appendingPathComponent("icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"))
        }
    }
}
