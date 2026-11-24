using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>Mac <c>QualityTest</c>: the highest full-motion resolution and fps the link and the receiver keep up, then the fps of typical use.</summary>
public static class QualityTest
{
    public sealed class Stage
    {
        public PixelSize Size { get; set; } = new();
        public double Fps { get; set; }
        public double Gbps { get; set; }
        /// <summary>Video layer carrying motion; null on the tile path.</summary>
        public PixelSize? Motion { get; set; }
        /// <summary>Video bitrate the stage ran at.</summary>
        public int? VideoBitrate { get; set; }
    }

    /// <summary>Progress and results, published through the session snapshot.</summary>
    public sealed class Report
    {
        public string Receiver { get; set; } = "";
        public LinkKind? Link { get; set; }
        public string Path { get; set; } = "";
        /// <summary>Full-motion stages, smallest first.</summary>
        public List<Stage> Stages { get; } = new();
        /// <summary>A video window and scrolling text only, at the session's size.</summary>
        public Stage? Typical { get; set; }
        /// <summary>Size being measured; null once finished.</summary>
        public PixelSize? Running { get; set; }
        public bool RunningTypical { get; set; }
        public int Total { get; set; }
        /// <summary>The receiver's refresh: the rate stages aim for.</summary>
        public double FrameRate { get; set; } = 60;
        public bool Finished { get; set; }

        public Stage? Verdict => QualityTest.Verdict(Stages, FrameRate);
        public int Done => Stages.Count + (Typical is null ? 0 : 1);
    }

    /// <summary>Panel fractions measured: a 5K panel gives 1080p, 1440p, 4K, 5K.</summary>
    public static readonly double[] Scales = { 0.375, 0.5, 0.75, 1.0 };
    /// <summary>Measured part of each stage.</summary>
    public const double MeasureSeconds = 2.0;
    /// <summary>Longest wait for the receiver's window to show.</summary>
    public const double ShowWait = 5.0;
    /// <summary>Smooth: 55 of 60 frames, at any refresh.</summary>
    public const double SmoothShare = 55.0 / 60;

    public static double SmoothFps(double frameRate) => frameRate * SmoothShare;

    /// <summary>
    /// Skipped at stage start (at most 5 s): the receiver's fps counter spans one second, and the tile path opens with lossless
    /// frames, one byte per pixel, which slow links take a while to carry.
    /// </summary>
    public static double Warmup(PixelSize stage, double? capacityGbps) =>
        Math.Min(5, 1 + 2.0 * stage.Width * stage.Height * 8 / (Math.Max(0.01, capacityGbps ?? 0) * 1e9));

    public static IReadOnlyList<PixelSize> Stages(PixelSize panel) =>
        Scales.Select(s => Aligned(new PixelSize((int)(panel.Width * s), (int)(panel.Height * s)))).ToList();

    /// <summary>BC7 blocks need sizes in multiples of 4.</summary>
    public static PixelSize Aligned(PixelSize p) => new(p.Width / 4 * 4, p.Height / 4 * 4);

    public static string Label(PixelSize s) => s.Width >= 5000 ? "5K" : s.Width >= 3800 ? "4K" : $"{s.Height}p";

    /// <summary>Mac <c>QualityTest.linkName</c>: English, never localised (photos of the screen name it).</summary>
    public static string LinkName(LinkKind link) => link switch
    {
        LinkKind.thunderbolt => "Thunderbolt",
        LinkKind.usb => "USB",
        LinkKind.ethernet => "Ethernet",
        LinkKind.wifi => "Wi-Fi",
        LinkKind.loopback => "Loopback",
        _ => "Unsupported link",
    };

    /// <summary>
    /// Mac <c>QualityTest.caption</c>: drawn on the pattern. English, like a test card.
    /// Link first so a photo of the screen names the path.
    /// </summary>
    public static string Caption(PixelSize size, LinkKind link, int step, int of, bool typical)
    {
        var stage = typical
            ? $"Typical use · {size.Width}×{size.Height} · {step}/{of}"
            : $"{Label(size)} · {step}/{of} · Full motion";
        return $"{LinkName(link)} · {stage}";
    }

    /// <summary>Largest stage at a smooth frame rate.</summary>
    public static Stage? Verdict(IReadOnlyList<Stage> stages, double frameRate) =>
        stages.Where(s => s.Fps >= SmoothFps(frameRate)).OrderByDescending(s => (long)s.Size.Width * s.Size.Height).FirstOrDefault();
}
