namespace Afterscreen.Protocol;

/// <summary>
/// BC1 (DXT1) block — Mac TileEncoder motion path / receiver bc1ToBC7 transcoder.
/// Colour mode only (c0 &gt; c1): palette c0, c1, 21/64, 43/64.
/// </summary>
public static class Bc1
{
    public const int BlockBytes = 8;
    private static readonly int[] Weights = [0, 64, 21, 43]; // index → /64 toward c1

    public static void EncodeBlock(
        ReadOnlySpan<(byte r, byte g, byte b, byte a)> px,
        Span<byte> dst)
    {
        if (dst.Length < BlockBytes)
            throw new ArgumentException("BC1 block is 8 bytes", nameof(dst));

        var minL = int.MaxValue;
        var maxL = int.MinValue;
        var e0 = px[0];
        var e1 = px[0];
        for (var i = 0; i < 16; i++)
        {
            var l = 2 * px[i].r + 5 * px[i].g + px[i].b;
            if (l < minL) { minL = l; e0 = px[i]; }
            if (l > maxL) { maxL = l; e1 = px[i]; }
        }

        var c0 = Pack565(e1.r, e1.g, e1.b); // brighter → c0
        var c1 = Pack565(e0.r, e0.g, e0.b);
        if (c0 < c1)
            (c0, c1) = (c1, c0);
        else if (c0 == c1 && maxL != minL)
            c0 = (ushort)Math.Min(0xFFFF, c0 + 1);

        Span<byte> idx = stackalloc byte[16];
        if (c0 == c1)
            idx.Clear();
        else
        {
            var p0 = Unpack565(c0);
            var p1 = Unpack565(c1);
            for (var i = 0; i < 16; i++)
            {
                var best = 0;
                var bestErr = int.MaxValue;
                for (var k = 0; k < 4; k++)
                {
                    var w = Weights[k];
                    var r = (p0.r * (64 - w) + p1.r * w) / 64;
                    var g = (p0.g * (64 - w) + p1.g * w) / 64;
                    var b = (p0.b * (64 - w) + p1.b * w) / 64;
                    var dr = px[i].r - r;
                    var dg = px[i].g - g;
                    var db = px[i].b - b;
                    var err = dr * dr + dg * dg + db * db;
                    if (err < bestErr) { bestErr = err; best = k; }
                }
                idx[i] = (byte)best;
            }
        }

        dst[0] = (byte)c0;
        dst[1] = (byte)(c0 >> 8);
        dst[2] = (byte)c1;
        dst[3] = (byte)(c1 >> 8);
        uint bits = 0;
        for (var i = 0; i < 16; i++)
            bits |= (uint)(idx[i] & 3) << (2 * i);
        dst[4] = (byte)bits;
        dst[5] = (byte)(bits >> 8);
        dst[6] = (byte)(bits >> 16);
        dst[7] = (byte)(bits >> 24);
    }

    private static ushort Pack565(byte r, byte g, byte b) =>
        (ushort)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));

    private static (byte r, byte g, byte b) Unpack565(ushort c)
    {
        var r5 = (c >> 11) & 31;
        var g6 = (c >> 5) & 63;
        var b5 = c & 31;
        return ((byte)((r5 << 3) | (r5 >> 2)), (byte)((g6 << 2) | (g6 >> 4)), (byte)((b5 << 3) | (b5 >> 2)));
    }
}
