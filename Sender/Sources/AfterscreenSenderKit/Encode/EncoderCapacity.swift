import CoreVideo
import Foundation
import AfterscreenCore

/// Frames per second this Mac's hardware encoder sustains per layer
/// Measured once per size and kept while the app runs
/// Pipelined like the stream, every frame changed in full
/// Slower Macs then take a smaller video layer
enum EncoderCapacity {
    /// fps per layer, and when measured
    private static var measured: [String: (fps: Double, at: TimeInterval)] = [:]
    private static let lock = NSLock()
    /// Timed frames, about half a second at 60 fps
    static let frames = 30
    /// Not timed: first keyframe, encoder warming up
    static let warmup = 3
    /// Headroom over the stream's rate
    static let margin = 1.05
    /// Busy encoders read short: low results measured again after this
    static let retrySeconds: TimeInterval = 600

    /// First of `sizes`, largest first, kept up at `fps`; blocks
    /// None keeps up: the smallest
    static func largest(of sizes: [PixelSize], codec: VideoCodec, tenBit: Bool, bitrate: Int, fps: Double) -> PixelSize? {
        sizes.first { framesPerSecond($0, codec: codec, tenBit: tenBit, bitrate: bitrate, wanted: fps) >= fps * margin } ?? sizes.last
    }

    private static func framesPerSecond(_ size: PixelSize, codec: VideoCodec, tenBit: Bool, bitrate: Int, wanted: Double) -> Double {
        let k = key(size, codec, tenBit), now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let kept = measured[k], kept.fps >= wanted * margin || now - kept.at < retrySeconds { lock.unlock(); return kept.fps }
        lock.unlock()
        let fps = measure(size, codec: codec, tenBit: tenBit, bitrate: bitrate, wanted: wanted)
        lock.lock()
        measured[k] = (fps, now)
        lock.unlock()
        return fps
    }

    private static func key(_ size: PixelSize, _ codec: VideoCodec, _ tenBit: Bool) -> String {
        "\(codec.rawValue)\(tenBit ? "10" : "8")-\(size.width)x\(size.height)"
    }

    /// Moving frames back to back, as fast as accepted
    /// Timed after the warm-up; 0 when the encoder cannot start
    private static func measure(_ size: PixelSize, codec: VideoCodec, tenBit: Bool, bitrate: Int, wanted: Double) -> Double {
        let layer = VideoLayer(codec: codec, pixels: size, bitrate: bitrate, tenBit: tenBit)
        guard let encoder = VideoEncoder(layer: layer, fps: wanted) else { return 0 }
        let sources = (0..<3).compactMap { frame(size, phase: $0) }
        guard sources.count == 3 else { return 0 }
        let warm = DispatchGroup(), done = DispatchGroup()
        var start = 0.0
        for i in 0..<(warmup + frames) {
            let group = i < warmup ? warm : done
            group.enter()
            if !encoder.encode(sources[i % 3], time: Double(i) / wanted, forceKeyframe: i == 0, completion: { _ in group.leave() }) { group.leave() }
            guard i == warmup - 1 else { continue }
            guard warm.wait(timeout: .now() + 5) == .success else { return 0 }
            start = ProcessInfo.processInfo.systemUptime
        }
        guard done.wait(timeout: .now() + 10) == .success else { return 0 }
        return Double(frames) / max(1e-3, ProcessInfo.processInfo.systemUptime - start)
    }

    /// Video-like BGRA frame: smooth colour waves, light grain
    /// Every pixel moves between phases
    /// Pure noise would overstate the cost of real motion
    private static func frame(_ size: PixelSize, phase: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let wave = (0..<256).map { Int(100 + 100 * sin(Double($0) * .pi / 128)) }
        // xorshift grain, 0…31
        var x32 = UInt32(phase + 1) &* 2_654_435_761
        for y in 0..<size.height {
            let row = (base + y * rowBytes).bindMemory(to: UInt32.self, capacity: size.width)
            let g = wave[(y / 3 + phase * 7) & 255]
            for x in 0..<size.width {
                x32 ^= x32 << 13
                x32 ^= x32 >> 17
                x32 ^= x32 << 5
                let grain = Int(x32 & 31)
                let r = wave[(x / 4 + phase * 9) & 255] + grain
                let b = wave[((x + y) / 5 + phase * 5) & 255] + grain
                row[x] = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g + grain) << 8 | UInt32(b)
            }
        }
        return buffer
    }
}
