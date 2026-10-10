import CoreGraphics
import Foundation
import ImageIO

enum ScreenSnapshotError: Error {
    case encode
}

/// What the receiver draws, saved as a 16-bit PNG. Screen captures over SSH lack Screen Recording
/// permission and show the desktop picture instead of the stream; this needs none
enum ScreenSnapshot {
    /// Drawable words (blue in the low ten bits, then green, red and two alpha bits) as 16-bit RGB
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
