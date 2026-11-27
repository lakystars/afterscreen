namespace Afterscreen.Sender.Encode;

/// <summary>
/// Phase B: GPU NV12/P010 into QSV without CPU readback.
/// <c>AFTERSCREEN_VIDEO_ZEROCOPY=0</c> keeps the A′ CPU upload path (default: on).
/// DXGI attempt order is NOT flipped globally — only explicit <c>TryCreate(..., preferDxgi: true)</c>
/// or <c>AFTERSCREEN_MF_FORCE_DXGI=1</c> (CLI prove / soak).
/// </summary>
internal static class VideoZeroCopy
{
    public static bool Wanted
    {
        get
        {
            var v = Environment.GetEnvironmentVariable("AFTERSCREEN_VIDEO_ZEROCOPY");
            if (string.IsNullOrWhiteSpace(v)) return true;
            return !(v == "0" || v.Equals("false", StringComparison.OrdinalIgnoreCase)
                     || v.Equals("off", StringComparison.OrdinalIgnoreCase));
        }
    }

    /// <summary>Env-only: <c>AFTERSCREEN_MF_FORCE_DXGI=1</c>. Does not follow <see cref="Wanted"/>.</summary>
    public static bool PreferDxgiManager =>
        string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_FORCE_DXGI"), "1", StringComparison.Ordinal);
}
