namespace Afterscreen.Protocol;

/// <summary>Mac <c>PanelLight</c> / <c>BrightnessWire</c>: f32 nits (−1 = unknown), f32 slider 0…1.</summary>
public readonly record struct PanelLight(double? Nits, double Level);

public static class BrightnessWire
{
    private const double NitsLimit = 10_000.0;

    public static byte[] Encode(PanelLight light)
    {
        var w = new ByteWriter(8);
        var nits = light.Nits is { } n && !double.IsNaN(n)
            ? (float)Math.Clamp(n, 0, NitsLimit)
            : -1f;
        var level = double.IsNaN(light.Level) ? 0f : (float)Math.Clamp(light.Level, 0, 1);
        w.F32(nits);
        w.F32(level);
        return w.ToArray();
    }

    public static PanelLight Decode(ReadOnlySpan<byte> data)
    {
        var r = new ByteReader(data);
        var nits = r.U32();
        var levelBits = r.U32();
        var n = BitConverter.UInt32BitsToSingle(nits);
        var level = BitConverter.UInt32BitsToSingle(levelBits);
        return new PanelLight(
            n >= 0 && float.IsFinite(n) ? Math.Min(NitsLimit, n) : null,
            float.IsNaN(level) ? 0 : Math.Clamp(level, 0, 1));
    }
}
