import AfterscreenCore

/// Picks tile or hybrid path from link, probe, receiver capabilities
public enum PathPolicy {
    /// Receiver panel's physical size; receivers without it get one
    /// from points at 110 per inch, macOS's desktop density
    public static func millimeters(_ w: Welcome) -> PixelSize {
        w.panelMillimeters ?? PixelSize(width: w.panelPoints.width * 254 / 1100, height: w.panelPoints.height * 254 / 1100)
    }

    /// Lossless tiles carry full-screen motion at this many bits
    /// per pixel per frame: 2.5 Gbps at 5K, 60 fps
    static let tileBitsPerPixel = 2.8

    /// Link rate the tile path needs at this size, rate
    public static func tileCapacityGbps(_ stream: PixelSize, fps: Double) -> Double {
        Double(stream.pixelCount) * fps * tileBitsPerPixel / 1e9
    }

    /// Video layer sizes, largest first
    /// Whether this Mac encodes one in time: `EncoderCapacity`
    /// H.264 stops at 1440p (level 5.1)
    /// 4K60 needs level 5.2, beyond 2014–2015 iMac decoders without HEVC
    static let videoSizes = [PixelSize(width: 3840, height: 2160), PixelSize(width: 2560, height: 1440), PixelSize(width: 1920, height: 1080)]
    /// Minimum bits per pixel per frame
    /// Apple's 75 Mbps for 4K screen sharing at 60 fps
    static let minBitsPerPixel = 0.15

    /// Automatic keeps the panel's size while the link settles
    /// a full screen of lossless tiles within this time
    static let fullSettleSeconds = 0.25

    /// Valid receiver panel sizes; others mean a bad peer
    /// Up to 8K, whose raw frame fits one message
    static let widthRange = 640...7680
    static let heightRange = 480...4320

    /// `source`: mirrored display's pixels; nil streams a panel-sized display
    /// `largestVideo`: biggest layer this Mac encodes at the receiver's rate
    public static func choose(link: LinkKind, capacityGbps: Double?, welcome: Welcome, resolution: StreamResolution = .panel,
                              source: PixelSize? = nil, largestVideo: PixelSize? = nil) -> StreamConfig? {
        guard link != .unsupported, isPlausible(welcome) else { return nil }
        let screen = aligned(welcome.panelPixels)
        let picked = resolve(resolution, panel: screen, source: source, capacityGbps: capacityGbps)
        let panel = streamPixels(panel: screen, capacityGbps: capacityGbps, resolution: picked, source: source)
        let fps = welcome.frameRate
        let tiles = StreamConfig(path: .tile, streamPixels: panel, video: nil, linkKind: link, frameRate: fps)
        if link.isWired, (capacityGbps ?? 0) >= tileCapacityGbps(panel, fps: fps) { return tiles }
        guard welcome.hevcDecode || welcome.h264Decode else { return tiles }
        let codec: VideoCodec = welcome.hevcDecode ? .hevc : .h264
        let rate = bitrate(capacityGbps: capacityGbps)
        // Mirror keeps still areas 1:1 where extend sends four fifths
        // Moving areas take the four fifths: video cost unchanged
        let motion = source.map { s -> PixelSize in
            guard picked == .reduced else { return panel }
            let full = aligned(fit(s, within: screen))
            return fit(aligned(PixelSize(width: full.width * 4 / 5, height: full.height * 4 / 5)), within: panel)
        } ?? panel
        let video = VideoLayer(codec: codec, pixels: videoPixels(motion, bitrate: rate, codec: codec, fps: fps, largest: largestVideo),
                               bitrate: rate, tenBit: codec == .hevc && welcome.hevcMain10Decode)
        return StreamConfig(path: .hybrid, streamPixels: panel, video: video, linkKind: link, frameRate: fps)
    }

    /// Captured size
    /// Four fifths per axis sends 64% of the pixels
    /// Holds 60 fps of full-screen motion on slow links
    /// Virtual display keeps panel size; desktop looks unchanged
    /// Receiver scales the stream up by 1.25
    /// Mirror: the source's own pixels within that size
    /// A smaller source goes 1:1; resampling only blurs it
    /// The receiver scales once and letterboxes the rest
    static func streamPixels(panel: PixelSize, capacityGbps: Double?, resolution: StreamResolution, source: PixelSize? = nil) -> PixelSize {
        let reduce = resolve(resolution, panel: panel, source: source, capacityGbps: capacityGbps) == .reduced
        let limit = reduce ? aligned(PixelSize(width: panel.width * 4 / 5, height: panel.height * 4 / 5)) : panel
        return source.map { aligned(fit($0, within: limit)) } ?? limit
    }

    /// Automatic made concrete by the measured rate, any link kind
    /// Measured against the stream sent: a mirrored display's own size
    /// `previous`, this receiver's last pick, holds within 20%
    /// Rates near the line would flip the desktop each session
    public static func resolve(_ resolution: StreamResolution, panel: PixelSize, source: PixelSize?, capacityGbps: Double?,
                               previous: StreamResolution? = nil) -> StreamResolution {
        guard resolution == .auto else { return resolution }
        let need = fullScreenGbps(source.map { aligned(fit($0, within: panel)) } ?? panel)
        let line = previous == .reduced ? need * 1.2 : (previous == .panel ? need / 1.2 : need)
        return (capacityGbps ?? 0) < line ? .reduced : .panel
    }

    /// Rate that settles a full stream in `fullSettleSeconds`
    /// `settleTiles`: raw BC7 at the link rate, half after LZ4
    /// 5K: 0.47 Gbps, under gigabit Ethernet
    public static func fullScreenGbps(_ stream: PixelSize) -> Double {
        Double(stream.pixelCount) * 8 / fullSettleSeconds / 1e9
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
    static func stage(_ config: StreamConfig, size: PixelSize, largestVideo: PixelSize? = nil) -> StreamConfig {
        var c = config
        c.streamPixels = size
        c.video.map { c.video?.pixels = videoPixels(size, bitrate: $0.bitrate, codec: $0.codec, fps: config.frameRate, largest: largestVideo) }
        c.test = true
        return c
    }

    /// Largest layer the bitrate fills, within what the encoder sustains
    /// Larger layers push hard content to the quality floor
    /// Encoder then overshoots the link
    static func videoPixels(_ stream: PixelSize, bitrate: Int, codec: VideoCodec, fps: Double, largest: PixelSize? = nil) -> PixelSize {
        let boxes = videoBoxes(bitrate: bitrate, codec: codec, fps: fps)
        let box = boxes.first { b in largest.map { b.pixelCount <= $0.pixelCount } ?? true } ?? boxes[boxes.count - 1]
        return fit(stream, within: box)
    }

    /// Layer sizes the bitrate fills at `minBitsPerPixel`, largest first
    public static func videoBoxes(bitrate: Int, codec: VideoCodec, fps: Double) -> [PixelSize] {
        let sizes = codec == .hevc ? videoSizes : Array(videoSizes.dropFirst())
        let first = sizes.firstIndex { Double(bitrate) / fps / Double($0.pixelCount) >= minBitsPerPixel } ?? sizes.count - 1
        return Array(sizes[first...])
    }

    static func isPlausible(_ w: Welcome) -> Bool {
        let p = w.panelPixels, pt = w.panelPoints
        return widthRange.contains(p.width) && heightRange.contains(p.height)
            && pt.width >= 320 && pt.height >= 240 && pt.width <= p.width && pt.height <= p.height
    }

    /// Settled tiles per hybrid frame
    /// Half the link's per-frame budget
    /// Assumes the typical 2:1 LZ4 ratio
    public static func settleTiles(capacityGbps: Double?, tileBytes: Int, fps: Double) -> Int {
        max(16, Int((capacityGbps ?? 0) * 1e9 / 8 / fps / Double(tileBytes)))
    }

    /// Moving tiles per frame sent as BC7, not BC1
    /// Half the link per frame, no LZ4 credit
    /// BC1's 5:6:5 endpoints band gradients and tint greys
    /// The BC7 encoding already exists
    public static func bc7MotionTiles(capacityGbps: Double?, tileBytes: Int, fps: Double) -> Int {
        Int((capacityGbps ?? 0) * 0.5e9 / 8 / fps / Double(tileBytes))
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
