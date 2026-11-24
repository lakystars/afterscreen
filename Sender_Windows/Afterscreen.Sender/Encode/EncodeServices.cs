using Afterscreen.Protocol;

namespace Afterscreen.Sender.Encode;

public enum TileBackendKind
{
    /// <summary>CPU BC7 (current default).</summary>
    Cpu,
    /// <summary>D3D11 compute BC7 — adapter via DXGI (Iris/NVIDIA/AMD). Not wired yet.</summary>
    D3d11,
    /// <summary>Try D3D11, else CPU.</summary>
    Auto,
}

public sealed class EncodeOptions
{
    public TileBackendKind TileBackend { get; init; } = TileBackendKind.Auto;
    /// <summary>Preferred DXGI adapter; null = GpuAdapters.Prefer().</summary>
    public GpuAdapterInfo? Adapter { get; init; }
}

/// <summary>Session-facing encode stack: tiles always, video when hybrid.</summary>
public sealed class EncodePipeline : IDisposable
{
    public required ITileEncoder Tiles { get; init; }
    public IVideoEncoder? Video { get; init; }
    public required StreamConfig Config { get; init; }
    public GpuAdapterInfo? Adapter { get; init; }
    /// <summary>Shared D3D device for the preferred adapter (HLSL BC7 / MF DXGI later).</summary>
    public D3dEncodeDevice? D3d { get; init; }
    public string Summary { get; init; } = "";

    public void Dispose()
    {
        Tiles.Dispose();
        Video?.Dispose();
        D3d?.Dispose();
    }
}

public static class EncodeServices
{
    /// <summary>
    /// Picks tile + optional MF video. GPU choice is DXGI adapter based —
    /// new vendors need an adapter match + backend plugin, not session changes.
    /// </summary>
    public static EncodePipeline Create(Welcome welcome, LinkKind link, double? capacityGbps, EncodeOptions? options = null,
        PixelSize? streamOverride = null, bool test = false, string streamResolution = "auto")
    {
        options ??= new EncodeOptions();
        var adapter = options.Adapter ?? GpuAdapters.Prefer();
        var d3d = D3dEncodeDevice.TryCreate(adapter);
        // Mac streams at the receiver's refresh rate. The old 30 fps cap worked around a ~10 ms
        // CPU readback/scale/probe cost that dirty-rect capture removed; the frame gate also
        // aliased against the 60 Hz desktop at 30 (sent 24, cap 48). Cap at 60 (the measured
        // steady state under full-screen motion); AFTERSCREEN_FPS overrides for measurement.
        var fpsCap = int.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_FPS"), out var envFps)
            && envFps is >= 1 and <= 120 ? envFps : 60;
        var fps = Math.Min(fpsCap, Math.Max(1, welcome.FrameRate));
        // Mac streams panel size; Metal dirty+VT are cheap there. On Windows, CPU
        // Probe/TileChanged over 2880×1620 alone drifted enc to ~45ms and sentFPS~7.
        // Match SoftBoxes[0] until GPU dirty detect (or HEVC/10-bit) lands.
        // Stream at the monitor's own size so text is copied 1:1. The old fixed 1920x1080
        // box squashed a 1920x1200 laptop panel (nearest, 0.9 vertical) which smeared text. Bigger
        // monitors are fitted (aspect kept) into MirrorMax (4096x2304 by default).
        // Mac PathPolicy.streamPixels: auto/panel/reduced against the receiver panel.
        var stream = streamOverride ?? ChooseStream(welcome, capacityGbps, streamResolution);

        // Own D3D device for BC7 compute — sharing the MF/QSV device+context
        // grew native WS unboundedly under hybrid settle.
        var tiles = CreateTileEncoder(options.TileBackend, adapter, stream.Width, stream.Height, sharedD3d: null);
        IVideoEncoder? video = null;
        VideoLayer? layer = null;
        var path = StreamPath.tile;

        // Mac Sender: hybrid whenever the receiver decodes H.264/HEVC. Motion → video
        // layer + .video tile runs; still UI → BC7. AFTERSCREEN_HYBRID=0 forces tile-only.
        var hybridEnv = Environment.GetEnvironmentVariable("AFTERSCREEN_HYBRID");
        // HEVC (Mac PathPolicy picks it whenever the receiver decodes it) is opt-in until verified on
        // screen: AFTERSCREEN_CODEC=hevc. Falls back to H.264 if no HEVC encoder proves output.
        var wantHevc = string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_CODEC"), "hevc",
            StringComparison.OrdinalIgnoreCase) && welcome.HevcDecode;
        var preferHybrid = (welcome.H264Decode || wantHevc) && !string.Equals(hybridEnv, "0", StringComparison.Ordinal);

        if (preferHybrid)
        {
            // Mac PathPolicy.bitrate: 40% of the link, clamped 20…200 Mbps (no extra Windows ceiling).
            // AFTERSCREEN_VIDEO_MBPS is an optional tighter cap only when set.
            var bitrate = VideoBitrateMbps(capacityGbps);
            // HEVC first when opted in and the receiver decodes it; otherwise (or if no HEVC encoder
            // proves output) H.264.
            // Mac PathPolicy: HEVC Main10 when the receiver decodes it (Welcome.HevcMain10Decode), else HEVC Main,
            // else H.264. AFTERSCREEN_TENBIT=0 skips Main10.
            var wantTen = wantHevc && welcome.HevcMain10Decode
                && !string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_TENBIT"), "0", StringComparison.Ordinal);
            var order = new List<(VideoCodec Codec, bool Ten)>();
            if (wantTen) order.Add((VideoCodec.hevc, true));
            if (wantHevc) order.Add((VideoCodec.hevc, false));
            order.Add((VideoCodec.h264, false));
            foreach (var (codec, ten) in order)
            {
                if (codec == VideoCodec.h264 && !welcome.H264Decode)
                    continue;
                // Mac PathPolicy.videoPixels + EncoderCapacity: the largest layer box the bitrate fills and this encoder keeps up
                // at the stream's rate (measured once per size and kept while the process runs)
                // The video layer may be as large as the stream itself - the external display's size (AFTERSCREEN_VIDEO_MAX caps it)
                var boxes = EncoderCapacity.VideoBoxes(bitrate, codec, fps, VideoMaxOverride ?? stream);
                var box = EncoderCapacity.Largest(boxes, codec, ten, bitrate, fps, adapter, d3d);
                var videoPixels = FitWithin(stream, box);
                layer = new VideoLayer
                {
                    Codec = codec,
                    Pixels = videoPixels,
                    Bitrate = bitrate,
                    TenBit = ten,
                };
                try
                {
                    video = MfH264Encoder.TryCreate(layer, fps, adapter, d3d);
                    if (video is not null && !video.IsHardware)
                    {
                        // Mac FrameStreamer.fallBackToBC1: video only when the HW encoder works.
                        // SW MFT still aborts (ucrtbase 0xc0000409) under real desktop motion —
                        // do not keep a soft hybrid; stay on tiles until QSV ProcessOutput works.
                        video.Dispose();
                        video = null;
                    }
                }
                catch
                {
                    video = null;
                }
                if (video is not null)
                {
                    path = StreamPath.hybrid;
                    break;
                }
                layer = null;
            }
        }

        var config = new StreamConfig
        {
            Path = path,
            StreamPixels = stream,
            Video = path == StreamPath.hybrid ? layer : null,
            LinkKind = link,
            Test = test,
            FrameRate = fps,
        };

        // Mac FrameStreamer.reconfigure: hybrid → motion=.video; else .bc1.
        tiles.Motion = path == StreamPath.hybrid && video is not null
            ? TileMotion.Video
            : TileMotion.Bc1;

        var d3dTag = d3d is not null ? $"; d3d={d3d.Adapter.Description}" : "";
        var summary = path == StreamPath.hybrid && video is not null
            ? $"stream={stream.Width}x{stream.Height}; tiles={tiles.BackendName}; video={video.BackendName}; {layer!.Pixels.Width}x{layer.Pixels.Height} @{layer.Bitrate / 1_000_000}Mbps{d3dTag}"
            : $"stream={stream.Width}x{stream.Height}; tiles={tiles.BackendName}; path=tile; motion={tiles.Motion}{d3dTag}";

        return new EncodePipeline
        {
            Tiles = tiles,
            Video = video,
            Config = config,
            Adapter = adapter,
            D3d = d3d,
            Summary = summary,
        };
    }

    /// <summary>The session's stream size: the monitor's own size, fitted into <see cref="MirrorMax"/>.</summary>
    public static PixelSize DefaultStream()
    {
        var native = Capture.DxgiCapture.QueryPrimarySize();
        return native is { } n
            ? FitWithin(new PixelSize(n.Width, n.Height), MirrorMax)
            : FitWithin(
                new PixelSize(Sender.Session.SenderSession.StreamWidth, Sender.Session.SenderSession.StreamHeight),
                SoftBoxes[0]);
    }

    /// <summary>Mac <c>PathPolicy.streamPixels</c>: fit capture into panel (or 4/5 panel when reduced).</summary>
    public static PixelSize ChooseStream(Welcome welcome, double? capacityGbps, string resolution)
    {
        var source = DefaultStream();
        var panel = welcome.PanelPixels is { Width: >= 640, Height: >= 480 } p
            ? new PixelSize(p.Width, p.Height)
            : MirrorMax;
        var resolved = ResolveStreamResolution(resolution, panel, source, capacityGbps);
        var limit = resolved == "reduced" ? FourFifths(panel) : panel;
        if (limit.Width > MirrorMax.Width || limit.Height > MirrorMax.Height)
            limit = FitWithin(limit, MirrorMax);
        return FitWithin(source, limit);
    }

    /// <summary>Mac <c>PathPolicy.resolve</c> for <c>StreamResolution.auto</c>.</summary>
    public static string ResolveStreamResolution(string resolution, PixelSize panel, PixelSize source, double? capacityGbps,
        string? previous = null)
    {
        if (resolution is "panel" or "reduced") return resolution;
        var need = FullScreenGbps(FitWithin(source, panel));
        var line = previous == "reduced" ? need * 1.2 : previous == "panel" ? need / 1.2 : need;
        return (capacityGbps ?? 0) < line ? "reduced" : "panel";
    }

    /// <summary>Mac <c>PathPolicy.fullScreenGbps</c> (settle 0.25 s of raw BC7).</summary>
    public static double FullScreenGbps(PixelSize stream) =>
        (double)stream.Width * stream.Height * 8 / 0.25 / 1e9;

    private static PixelSize FourFifths(PixelSize panel) =>
        new(Align4(panel.Width * 4 / 5), Align4(panel.Height * 4 / 5));

    public static ITileEncoder CreateTileEncoder(
        TileBackendKind kind, GpuAdapterInfo? adapter, int width, int height, D3dEncodeDevice? sharedD3d = null)
    {
        if (kind is TileBackendKind.D3d11 or TileBackendKind.Auto)
        {
            var d3d = D3dTileEncoder.TryCreate(adapter, width, height, sharedD3d);
            if (d3d is not null)
                return d3d;
            if (kind == TileBackendKind.D3d11)
                throw new NotSupportedException("D3D11 BC7 backend not available; check HLSL compile / adapter.");
        }
        return new CpuTileEncoder();
    }

    /// <summary>Mac EncoderCapacity.margin — headroom over the stream rate.</summary>
    internal const double CapacityMargin = 1.05;

    /// <summary>
    /// Mac H.264 boxes are 1440→1080. SW MFT often cannot hold 1080@fps;
    /// 720 is a Windows-only last rung below Mac's floor (same pattern as
    /// EncoderCapacity: first that sustains, else smallest).
    /// </summary>
    /// <summary>
    /// Largest stream before the monitor is scaled down (keeps CPU/link cost bounded). Default 4096x2304 is
    /// the size the Mac Sender reports for the 5K iMac; AFTERSCREEN_STREAM_MAX=WxH overrides it.
    /// A stream larger than the video layer is how still text stays crisp while motion stays cheap: tiles
    /// carry the full size, video is fitted into <see cref="VideoMax"/>.
    /// </summary>
    internal static readonly PixelSize MirrorMax = ParseSize(Environment.GetEnvironmentVariable("AFTERSCREEN_STREAM_MAX"))
                                                  ?? new PixelSize(4096, 2304);

    private static PixelSize? ParseSize(string? spec)
    {
        if (string.IsNullOrWhiteSpace(spec)) return null;
        var m = System.Text.RegularExpressions.Regex.Match(spec, @"^(\d+)x(\d+)$");
        if (!m.Success) return null;
        int w = int.Parse(m.Groups[1].Value), h = int.Parse(m.Groups[2].Value);
        return w >= 640 && h >= 480 && w <= 7680 && h <= 4320 ? new PixelSize(w, h) : null;
    }

    /// <summary>Largest video-layer size (Mac H.264/HEVC box); the layer is also fitted to the stream.</summary>
    internal static readonly PixelSize? VideoMaxOverride = ParseSize(Environment.GetEnvironmentVariable("AFTERSCREEN_VIDEO_MAX"));

    internal static readonly PixelSize[] SoftBoxes =
    [
        new(1920, 1080),
        new(1280, 720),
    ];

    /// <summary>Mac PathPolicy.bitrate (use long — 0.4e9*Gbps overflows int32).</summary>
    public static int MacBitrate(double? capacityGbps)
    {
        var raw = (long)((capacityGbps ?? 0) * 0.4e9);
        return (int)Math.Clamp(raw, 20_000_000L, 200_000_000L);
    }

    /// <summary>Mac bitrate, optionally capped by <c>AFTERSCREEN_VIDEO_MBPS</c> when set (5…200).</summary>
    public static int VideoBitrateMbps(double? capacityGbps)
    {
        var bitrate = MacBitrate(capacityGbps);
        if (int.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_VIDEO_MBPS"), out var mbps)
            && mbps is >= 5 and <= 200)
            bitrate = Math.Min(bitrate, mbps * 1_000_000);
        return bitrate;
    }

    /// <summary>Mac EncoderCapacity.largest for SW MFT — timed full-motion frames.</summary>
    internal static PixelSize SoftLargest(PixelSize stream, int bitrate, double fps)
    {
        foreach (var box in SoftBoxes)
        {
            var fitted = FitWithin(stream, box);
            if (MeasureSoftFps(fitted, bitrate, fps) >= fps * CapacityMargin)
                return fitted;
        }
        return FitWithin(stream, SoftBoxes[^1]);
    }

    /// <summary>~Mac EncoderCapacity.measure: warm-up then timed frames.</summary>
    internal static double MeasureSoftFps(PixelSize size, int bitrate, double fps)
    {
        var layer = new VideoLayer
        {
            Codec = VideoCodec.h264,
            Pixels = size,
            Bitrate = bitrate,
            TenBit = false,
        };
        using var enc = MfH264Encoder.TryCreate(layer, fps, adapter: null, d3d: null);
        if (enc is null)
            return 0;
        var bgra = new byte[size.Width * size.Height * 4];
        const int warmup = 2;
        const int frames = 8;
        for (var i = 0; i < warmup; i++)
            enc.Encode(bgra, size.Width, size.Height, forceKeyframe: i == 0);
        var t0 = Environment.TickCount64;
        var produced = 0;
        for (var i = 0; i < frames; i++)
        {
            // Change a stripe so SW cannot short-circuit a still frame.
            var row = (i * 17) % size.Height;
            var o = row * size.Width * 4;
            for (var x = 0; x < size.Width * 4; x += 4)
                bgra[o + x] = (byte)(i * 37);
            if (enc.Encode(bgra, size.Width, size.Height, forceKeyframe: false) is not null)
                produced++;
        }
        var ms = Math.Max(1, Environment.TickCount64 - t0);
        return produced * 1000.0 / ms;
    }

    /// <summary>Mac PathPolicy.videoPixels for H.264 (no 4K box).</summary>
    internal static PixelSize MacVideoPixels(PixelSize stream, int bitrate, double fps)
    {
        // Largest-first boxes that meet minBitsPerPixel ≈ 0.15
        PixelSize[] boxes = [new(2560, 1440), new(1920, 1080)];
        const double minBpp = 0.15;
        var first = 0;
        for (; first < boxes.Length; first++)
        {
            var px = (double)boxes[first].Width * boxes[first].Height;
            if (bitrate / Math.Max(1.0, fps) / px >= minBpp)
                break;
        }
        if (first >= boxes.Length)
            first = boxes.Length - 1;
        return FitWithin(stream, boxes[first]);
    }

    private static PixelSize FitWithin(PixelSize src, PixelSize box)
    {
        if (src.Width <= box.Width && src.Height <= box.Height)
            return new PixelSize(Align4(src.Width), Align4(src.Height));
        var sx = box.Width / (double)src.Width;
        var sy = box.Height / (double)src.Height;
        var s = Math.Min(sx, sy);
        return new PixelSize(Align4(Math.Max(4, (int)(src.Width * s))), Align4(Math.Max(4, (int)(src.Height * s))));
    }

    private static int Align4(int v) => v / 4 * 4;
}
