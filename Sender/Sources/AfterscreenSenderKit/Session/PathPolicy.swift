import AfterscreenCore

/// Picks tile or hybrid path from link, probe, receiver capabilities
public enum PathPolicy {
    public static let tileCapacityGbps = 2.5
    /// Video layer sizes, largest first
    /// 4K: the sender's encoder pipelines it at 60 fps
    /// H.264 stops at 1440p (level 5.1)
    /// 4K60 needs level 5.2, beyond 2014–2015 iMac decoders without HEVC
    static let videoSizes = [PixelSize(width: 3840, height: 2160), PixelSize(width: 2560, height: 1440), PixelSize(width: 1920, height: 1080)]
    /// Minimum bits per pixel per frame at 60 fps
    /// Matches Apple's 75 Mbps for 4K screen sharing
    static let minBitsPerPixel = 0.15

    /// Valid receiver panel sizes; others mean a bad peer
    /// Up to 8K, whose raw frame fits one message
    static let widthRange = 640...7680
    static let heightRange = 480...4320

    public static func choose(link: LinkKind, capacityGbps: Double?, welcome: Welcome, resolution: StreamResolution = .panel) -> StreamConfig? {
        guard link != .unsupported, isPlausible(welcome) else { return nil }
        let panel = streamPixels(panel: aligned(welcome.panelPixels), link: link, resolution: resolution)
        let tiles = StreamConfig(path: .tile, streamPixels: panel, video: nil, linkKind: link)
        if link.isWired, (capacityGbps ?? 0) >= tileCapacityGbps { return tiles }
        guard welcome.hevcDecode || welcome.h264Decode else { return tiles }
        let codec: VideoCodec = welcome.hevcDecode ? .hevc : .h264
        let rate = bitrate(capacityGbps: capacityGbps)
        let video = VideoLayer(codec: codec, pixels: videoPixels(panel, bitrate: rate, codec: codec), bitrate: rate,
                               tenBit: codec == .hevc && welcome.hevcMain10Decode)
        return StreamConfig(path: .hybrid, streamPixels: panel, video: video, linkKind: link)
    }

    /// Captured size
    /// Four fifths per axis sends 64% of the pixels
    /// Holds 60 fps of full-screen motion over Wi-Fi
    /// Virtual display keeps panel size; desktop looks unchanged
    /// Receiver scales the stream up by 1.25
    static func streamPixels(panel: PixelSize, link: LinkKind, resolution: StreamResolution) -> PixelSize {
        let reduce = resolution == .reduced || (resolution == .auto && link == .wifi)
        return reduce ? aligned(PixelSize(width: panel.width * 4 / 5, height: panel.height * 4 / 5)) : panel
    }

    /// Virtual display modes and the initial one
    /// Reduced stream: starts where desktop backing equals the stream
    /// Points are half the stream size on Retina panels
    /// Captured without scaling; the receiver scales once
    /// Settings size applies at panel resolution
    static func displayModes(welcome: Welcome, stream: PixelSize, size: DisplaySize) -> (all: [PixelSize], initial: PixelSize) {
        var all = DisplaySize.allCases.map { $0.points(for: welcome.panelPoints) }
        guard stream != aligned(welcome.panelPixels) else { return (all, size.points(for: welcome.panelPoints)) }
        let scale = welcome.isRetina ? 2 : 1
        let matched = PixelSize(width: stream.width / scale, height: stream.height / scale)
        if !all.contains(matched) { all.append(matched) }
        return (all, matched)
    }

    /// A quality test stage of `config` at `size`
    static func stage(_ config: StreamConfig, size: PixelSize) -> StreamConfig {
        var c = config
        c.streamPixels = size
        c.video.map { c.video?.pixels = videoPixels(size, bitrate: $0.bitrate, codec: $0.codec) }
        c.test = true
        return c
    }

    /// Largest layer the bitrate fills at `minBitsPerPixel`
    /// Larger layers push hard content to the quality floor
    /// Encoder then overshoots the link
    static func videoPixels(_ stream: PixelSize, bitrate: Int, codec: VideoCodec) -> PixelSize {
        let sizes = codec == .hevc ? videoSizes : Array(videoSizes.dropFirst())
        let size = sizes.first { Double(bitrate) / 60 / Double($0.pixelCount) >= minBitsPerPixel } ?? sizes[sizes.count - 1]
        return fit(stream, within: size)
    }

    static func isPlausible(_ w: Welcome) -> Bool {
        let p = w.panelPixels, pt = w.panelPoints
        return widthRange.contains(p.width) && heightRange.contains(p.height)
            && pt.width >= 320 && pt.height >= 240 && pt.width <= p.width && pt.height <= p.height
    }

    /// Settled tiles per hybrid frame
    /// Half the link's 60 Hz frame budget
    /// Assumes the typical 2:1 LZ4 ratio
    public static func settleTiles(capacityGbps: Double?, tileBytes: Int) -> Int {
        max(16, Int((capacityGbps ?? 0) * 1e9 / 8 / 60 / Double(tileBytes)))
    }

    /// Moving tiles per frame sent as BC7, not BC1
    /// Half the link at 60 fps, no LZ4 credit
    /// BC1's 5:6:5 endpoints band gradients and tint greys
    /// The BC7 encoding already exists
    public static func bc7MotionTiles(capacityGbps: Double?, tileBytes: Int) -> Int {
        Int((capacityGbps ?? 0) * 0.5e9 / 8 / 60 / Double(tileBytes))
    }

    /// Video bitrate: 40% of the link, clamped to 20…200 Mbps
    /// Rest goes to lossless tiles
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
