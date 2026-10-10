import AfterscreenCore

/// Chooses the tile or hybrid path from link, probe and receiver capabilities
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
        let tiles = StreamConfig(path: .tile, streamPixels: panel, video: nil, linkKind: link)
        if link.isWired, (capacityGbps ?? 0) >= tileCapacityGbps { return tiles }
        guard welcome.hevcDecode || welcome.h264Decode else { return tiles }
        let codec: VideoCodec = welcome.hevcDecode ? .hevc : .h264
        let video = VideoLayer(codec: codec, pixels: videoPixels(panel, codec: codec), bitrate: bitrate(capacityGbps: capacityGbps))
        return StreamConfig(path: .hybrid, streamPixels: panel, video: video, linkKind: link)
    }

    /// A quality test stage of `config` at `size`
    static func stage(_ config: StreamConfig, size: PixelSize) -> StreamConfig {
        var c = config
        c.streamPixels = size
        c.video?.pixels = videoPixels(size, codec: config.video?.codec ?? .hevc)
        c.test = true
        return c
    }

    static func videoPixels(_ stream: PixelSize, codec: VideoCodec) -> PixelSize {
        fit(stream, within: codec == .hevc ? videoMax : h264Max)
    }

    static func isPlausible(_ w: Welcome) -> Bool {
        let p = w.panelPixels, pt = w.panelPoints
        return widthRange.contains(p.width) && heightRange.contains(p.height)
            && pt.width >= 320 && pt.height >= 240 && pt.width <= p.width && pt.height <= p.height
    }

    /// Settled tiles per hybrid frame: half a 60 Hz frame interval of the link, at the typical 2:1 LZ4 ratio
    public static func settleTiles(capacityGbps: Double?, tileBytes: Int) -> Int {
        max(16, Int((capacityGbps ?? 0) * 1e9 / 8 / 60 / Double(tileBytes)))
    }

    /// Video layer bitrate: 40% of the link, leaving the rest to lossless tiles; 20…200 Mbps
    public static func bitrate(capacityGbps: Double?) -> Int {
        min(200_000_000, max(20_000_000, Int((capacityGbps ?? 0) * 0.4e9)))
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
