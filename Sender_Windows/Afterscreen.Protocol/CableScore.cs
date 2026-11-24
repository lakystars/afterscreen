namespace Afterscreen.Protocol;

/// <summary>Mac <c>CableScore</c>: 0–100; 100 = clean link with headroom.</summary>
public static class CableScore
{
    /// <summary>Lossless tiles need this many bits/pixel/frame (Mac PathPolicy.tileBitsPerPixel).</summary>
    public const double TileBitsPerPixel = 2.8;

    public static double TileCapacityGbps(int width, int height, double fps) =>
        (long)width * height * fps * TileBitsPerPixel / 1e9;

    /// <summary>
    /// Required link rate for the current stream: hybrid uses 1.5× video bitrate;
    /// tile-only uses full-motion lossless tile capacity.
    /// </summary>
    public static double RequiredGbps(StreamConfig? config)
    {
        if (config is null) return 0;
        if (config.Video is { Bitrate: var br })
            return 1.5 * br / 1e9;
        var p = config.StreamPixels;
        return TileCapacityGbps(p.Width, p.Height, Math.Max(1, config.FrameRate));
    }

    public static int Score(double retransmitPercent, double jitterMs, double? capacityGbps, double requiredGbps)
    {
        var score = 100.0;
        score -= Math.Min(40, Math.Max(0, retransmitPercent) * 4);
        score -= Math.Min(30, Math.Max(0, jitterMs) * 3);
        if (capacityGbps is { } capacity && requiredGbps > 0)
            score -= 30 * Math.Max(0, 1 - capacity / requiredGbps);
        return Math.Clamp((int)Math.Round(score), 0, 100);
    }
}
