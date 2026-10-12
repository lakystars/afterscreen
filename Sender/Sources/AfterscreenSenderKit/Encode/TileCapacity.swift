import Foundation
import Metal
import AfterscreenCore

/// Time this Mac's tile encoder takes per full-motion frame
/// Every tile changes, all BC7: Thunderbolt's worst case
/// Measured once per size and kept while the app runs
enum TileCapacity {
    /// ms per frame, and when measured
    private static var measured: [String: (ms: Double, at: TimeInterval)] = [:]
    /// Held while timing: two probes would share the GPU
    private static let lock = NSLock()
    static let frames = 12
    /// Not timed: the GPU clocks up first
    static let warmupSeconds = 0.05
    static let warmupFrames = 2...30
    /// Busy GPUs read slow: slow results timed again after this
    static let retrySeconds: TimeInterval = 60

    /// Median wall time of one encode in ms; blocks
    /// Kept when within `limitMs`, else kept for `retrySeconds`
    /// nil without Metal
    static func fullMotionMs(_ size: PixelSize, limitMs: Double) -> Double? {
        let key = "\(size.width)x\(size.height)", now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if let kept = measured[key], kept.ms <= limitMs || now - kept.at < retrySeconds { return kept.ms }
        guard let ms = measure(size) else { return nil }
        measured[key] = (ms, now)
        return ms
    }

    private static func measure(_ size: PixelSize) -> Double? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let encoder = try? TileEncoder(device: device, geometry: TileGeometry(width: size.width, height: size.height), uploadBuffers: 1)
        else { return nil }
        encoder.bc7MotionLimit = encoder.geometry.tileCount
        guard let textures = noise(device, size) else { return nil }
        var times: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        var i = 0, warm = 0
        while times.count < frames {
            let t = ProcessInfo.processInfo.systemUptime
            // Discarded at once: its upload buffer frees for the next
            _ = encoder.encode(texture: textures[i % 2], forceAll: false, dirty: nil, now: Double(i) / HighRefresh.ceiling)
            let warming = warm < warmupFrames.upperBound && (warm < warmupFrames.lowerBound || t - start < warmupSeconds)
            if warming { warm += 1 } else { times.append((ProcessInfo.processInfo.systemUptime - t) * 1000) }
            i += 1
        }
        return times.sorted()[times.count / 2]
    }

    /// Two frames of random pixels: every tile changes
    private static func noise(_ device: MTLDevice, _ size: PixelSize) -> [MTLTexture]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        var textures: [MTLTexture] = []
        for _ in 0..<2 {
            guard let texture = device.makeTexture(descriptor: d) else { return nil }
            arc4random_buf(&bytes, bytes.count)
            texture.replace(region: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size.width * 4)
            textures.append(texture)
        }
        return textures
    }
}
