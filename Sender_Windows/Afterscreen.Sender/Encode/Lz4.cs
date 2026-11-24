using System.Buffers.Binary;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// LZ4 raw block format (what Apple's COMPRESSION_LZ4_RAW reads on the receiver): greedy hash-table matcher,
/// no frame header. Fast rather than tight - tile data is either very repetitive (UI) or incompressible (video-like).
/// </summary>
public static class Lz4
{
    public static int Bound(int count) => count + count / 255 + 16;

    [ThreadStatic] private static int[]? t_table;

    /// <summary>Compresses <paramref name="src"/> into <paramref name="dst"/> (at least <see cref="Bound"/> long); returns bytes written.</summary>
    public static int Compress(ReadOnlySpan<byte> src, Span<byte> dst)
    {
        var table = t_table ??= new int[1 << 16];
        Array.Clear(table);
        var n = src.Length;
        var op = 0;
        var anchor = 0;
        var ip = 0;
        var mflimit = n - 12;
        var matchlimit = n - 5;
        while (ip <= mflimit)
        {
            var seq = BinaryPrimitives.ReadUInt32LittleEndian(src[ip..]);
            var h = (int)((seq * 2654435761u) >> 16);
            var rp = table[h] - 1;
            table[h] = ip + 1;
            if (rp >= 0 && ip - rp <= 65535 && BinaryPrimitives.ReadUInt32LittleEndian(src[rp..]) == seq)
            {
                var mlen = 4;
                while (ip + mlen < matchlimit && src[rp + mlen] == src[ip + mlen]) mlen++;
                var lit = ip - anchor;
                var tokenPos = op++;
                var token = Math.Min(lit, 15) << 4;
                if (lit >= 15) op = WriteLength(dst, op, lit - 15);
                src.Slice(anchor, lit).CopyTo(dst[op..]);
                op += lit;
                BinaryPrimitives.WriteUInt16LittleEndian(dst[op..], (ushort)(ip - rp));
                op += 2;
                var ml = mlen - 4;
                token |= Math.Min(ml, 15);
                if (ml >= 15) op = WriteLength(dst, op, ml - 15);
                dst[tokenPos] = (byte)token;
                ip += mlen;
                anchor = ip;
            }
            else
            {
                ip += 1 + ((ip - anchor) >> 6);      // accelerate through incompressible stretches
            }
        }
        var last = n - anchor;
        dst[op++] = (byte)(Math.Min(last, 15) << 4);
        if (last >= 15) op = WriteLength(dst, op, last - 15);
        src[anchor..].CopyTo(dst[op..]);
        return op + last;
    }

    private static int WriteLength(Span<byte> dst, int op, int len)
    {
        while (len >= 255) { dst[op++] = 255; len -= 255; }
        dst[op++] = (byte)len;
        return op;
    }

    /// <summary>Decoder for tests and tools; returns false on malformed input.</summary>
    public static bool Decompress(ReadOnlySpan<byte> src, Span<byte> dst)
    {
        int ip = 0, op = 0;
        while (ip < src.Length)
        {
            var token = src[ip++];
            var lit = token >> 4;
            if (lit == 15) { int b; do { b = src[ip++]; lit += b; } while (b == 255); }
            if (op + lit > dst.Length || ip + lit > src.Length) return false;
            src.Slice(ip, lit).CopyTo(dst[op..]);
            ip += lit; op += lit;
            if (ip >= src.Length) break;
            var off = BinaryPrimitives.ReadUInt16LittleEndian(src[ip..]);
            ip += 2;
            var ml = token & 15;
            if (ml == 15) { int b; do { b = src[ip++]; ml += b; } while (b == 255); }
            ml += 4;
            if (off == 0 || off > op || op + ml > dst.Length) return false;
            for (var i = 0; i < ml; i++) { dst[op] = dst[op - off]; op++; }
        }
        return op == dst.Length;
    }
}
