import AfterscreenCore

/// Chooses tile or video path and stream size from link, probe and receiver capabilities
public enum PathPolicy {
    public static let tileCapacityGbps = 2.5
    public static let videoMax = PixelSize(width: 3840, height: 2160)
    public static let h264Max = PixelSize(width: 4096, height: 2304)

    /// Panel sizes a receiver may report (up to 8K, whose raw frame fits one message); anything else is a bad peer
    static let widthRange = 640...7680
    static let heightRange = 480...4320

    public static func choose(link: LinkKind, capacityGbps: Double?, welcome: Welcome) -> StreamConfig? {
        guard link != .unsupported, isPlausible(welcome) else { return nil }
        let panel = aligned(welcome.panelPixels)
        let points = welcome.panelPoints
        if link.isWired, (capacityGbps ?? 0) >= tileCapacityGbps {
            return StreamConfig(path: .tile, streamPixels: panel, sourcePoints: points, codec: nil, linkKind: link)
        }
        let codec: VideoCodec = welcome.hevcDecode ? .hevc : .h264
        var size = fit(panel, within: videoMax)
        if codec == .h264 { size = fit(size, within: h264Max) }
        return StreamConfig(path: .video, streamPixels: size, sourcePoints: points, codec: codec, linkKind: link)
    }

    static func isPlausible(_ w: Welcome) -> Bool {
        let p = w.panelPixels, pt = w.panelPoints
        return widthRange.contains(p.width) && heightRange.contains(p.height)
            && pt.width >= 320 && pt.height >= 240 && pt.width <= p.width && pt.height <= p.height
    }

    /// Video bitrate: 50 Mbps at 4K60, linear in pixels
    public static func bitrate(for size: PixelSize) -> Int {
        max(10_000_000, Int(50_000_000.0 * Double(size.pixelCount) / Double(videoMax.pixelCount)))
    }

    /// BC7 blocks need sizes in multiples of 4
    static func aligned(_ p: PixelSize) -> PixelSize {
        PixelSize(width: p.width / 4 * 4, height: p.height / 4 * 4)
    }

    static func fit(_ p: PixelSize, within limit: PixelSize) -> PixelSize {
        let scale = min(1, Double(limit.width) / Double(p.width), Double(limit.height) / Double(p.height))
        guard scale < 1 else { return p }
        return aligned(PixelSize(width: Int(Double(p.width) * scale), height: Int(Double(p.height) * scale)))
    }
}
