import CoreGraphics
import Foundation
import ImageIO

enum ScreenSnapshotError: Error {
    case encode
}

/// What the receiver draws, saved as a 16-bit PNG
/// Needs no Screen Recording permission; SSH screen captures lack it
/// and show the desktop picture instead of the stream
enum ScreenSnapshot {
    /// Drawable words to 16-bit RGB
    /// Blue in bits 0–9, green 10–19, red 20–29, alpha 30–31
    static func rgb16(fromBGR10A2 words: [UInt32]) -> [UInt16] {
        var out = [UInt16]()
        out.reserveCapacity(words.count * 3)
        for w in words {
            for shift: UInt32 in [20, 10, 0] {
                let v = (w >> shift) & 0x3FF
                out.append(UInt16((v * 65535 + 511) / 1023))
            }
        }
        return out
    }

    static func writePNG(words: [UInt32], width: Int, height: Int, to url: URL) throws {
        let rgb = rgb16(fromBGR10A2: words)
        let data = rgb.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ScreenSnapshotError.encode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenSnapshotError.encode }
    }
}
