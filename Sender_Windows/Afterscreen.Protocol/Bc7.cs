namespace Afterscreen.Protocol;

/// <summary>BC7 mode-6 helpers (matches Core BC7.swift).</summary>
public static class Bc7
{
    public const int BlockBytes = 16;

    public static byte[] MakeMode6(
        (byte r, byte g, byte b, byte a) e0,
        (byte r, byte g, byte b, byte a) e1,
        byte p0, byte p1, ReadOnlySpan<byte> indices)
    {
        if (indices.Length != 16 || indices[0] >= 8)
            throw new ArgumentException("mode6 indices");
        var bits = new BitWriter();
        bits.Write(0x40, 7);
        Span<byte> a = stackalloc byte[4];
        a[0] = e0.r; a[1] = e0.g; a[2] = e0.b; a[3] = e0.a;
        Span<byte> b = stackalloc byte[4];
        b[0] = e1.r; b[1] = e1.g; b[2] = e1.b; b[3] = e1.a;
        for (var c = 0; c < 4; c++)
        {
            bits.Write(a[c] & 0x7F, 7);
            bits.Write(b[c] & 0x7F, 7);
        }
        bits.Write(p0 & 1, 1);
        bits.Write(p1 & 1, 1);
        for (var i = 0; i < 16; i++)
            bits.Write(indices[i], i == 0 ? 3 : 4);
        return bits.Bytes;
    }

    /// <summary>Opaque solid block ≈ one RGBA color (7-bit endpoints, all indices 0).</summary>
    public static void WriteSolid(Span<byte> dest16, byte r, byte g, byte b, byte a = 255)
    {
        // Store high 7 bits in endpoint; p-bit = LSB so reconstructed 8-bit ≈ original.
        var e0 = ((byte)(r >> 1), (byte)(g >> 1), (byte)(b >> 1), (byte)(a >> 1));
        var block = MakeMode6(e0, e0, (byte)(r & 1), (byte)(a & 1),
            stackalloc byte[16]); // all zero
        block.CopyTo(dest16);
    }

    private struct BitWriter
    {
        public byte[] Bytes;
        private int _pos;
        public BitWriter()
        {
            Bytes = new byte[16];
            _pos = 0;
        }
        public void Write(int value, int count)
        {
            for (var i = 0; i < count; i++)
            {
                if (((value >> i) & 1) != 0)
                    Bytes[(_pos + i) >> 3] |= (byte)(1 << ((_pos + i) & 7));
            }
            _pos += count;
        }
    }
}
