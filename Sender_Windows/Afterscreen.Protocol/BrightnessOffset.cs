namespace Afterscreen.Protocol;

/// <summary>Mac <c>BrightnessOffset</c>: receiver light over the PC panel, in stops (−1…1). 0 matches nits.</summary>
public static class BrightnessOffset
{
    public const double Min = -1;
    public const double Max = 1;
    /// <summary>About 3.5% either side of even snaps to 0.</summary>
    public const double Snap = 0.05;
    /// <summary>Slider ≈ linear^(1/2.1) on Apple built-in panels.</summary>
    public const double SliderGamma = 2.1;

    public static double Snapped(double stops)
    {
        if (double.IsNaN(stops) || double.IsInfinity(stops) || Math.Abs(stops) < Snap) return 0;
        return Math.Clamp(stops, Min, Max);
    }

    public static double Gain(double stops) => Math.Pow(2, stops);

    /// <summary>Slider level for a receiver matched without nits.</summary>
    public static double Level(double level, double stops) =>
        Math.Clamp(level * Math.Pow(2, stops / SliderGamma), 0, 1);

    /// <summary>"+20%", "−50%", "0%".</summary>
    public static string Label(double stops)
    {
        var percent = (int)Math.Round((Gain(stops) - 1) * 100);
        if (percent > 0) return $"+{percent}%";
        if (percent < 0) return $"\u2212{-percent}%";
        return "0%";
    }
}
