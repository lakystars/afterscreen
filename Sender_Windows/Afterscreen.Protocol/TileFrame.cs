namespace Afterscreen.Protocol;

public readonly struct TileGeometry
{
    public int Width { get; }
    public int Height { get; }
    public int TileBlocks { get; }

    public TileGeometry(int width, int height, int tileBlocks = 16)
    {
        Width = width;
        Height = height;
        TileBlocks = tileBlocks;
    }

    public int TilePixels => TileBlocks * 4;
    public int BlocksX => (Width + 3) / 4;
    public int BlocksY => (Height + 3) / 4;
    public int TilesX => (Width + TilePixels - 1) / TilePixels;
    public int TilesY => (Height + TilePixels - 1) / TilePixels;
    public int TileCount => TilesX * TilesY;
}

public enum TileFormat : byte
{
    Bc7 = 0,
    Bc1 = 1,
    Video = 2,
}

public readonly struct TileRun
{
    public int Row { get; }
    public int First { get; }
    public int Count { get; }
    public TileFormat Format { get; }

    public TileRun(int row, int first, int count, TileFormat format = TileFormat.Bc7)
    {
        Row = row;
        First = first;
        Count = count;
        Format = format;
    }

    /// <summary>Covered BC7/BC1 blocks, clipped to the stream (matches Core TileRun.blocks).</summary>
    public (int W, int H) Blocks(TileGeometry g) =>
        (Math.Min(Count * g.TileBlocks, g.BlocksX - First * g.TileBlocks),
         Math.Min(g.TileBlocks, g.BlocksY - Row * g.TileBlocks));

    public int Bytes(TileGeometry g)
    {
        var (w, h) = Blocks(g);
        var blockBytes = Format switch
        {
            TileFormat.Bc7 => 16,
            TileFormat.Bc1 => 8,
            _ => 0,
        };
        return w * h * blockBytes;
    }

    /// <summary>Marked tiles → runs (mark 0 = clean, else format+1). BC7 then BC1 then video.</summary>
    public static List<TileRun> FromMarks(ReadOnlySpan<byte> marks, TileGeometry g)
    {
        var bc7 = new List<TileRun>();
        var bc1 = new List<TileRun>();
        var video = new List<TileRun>();
        for (var row = 0; row < g.TilesY; row++)
        {
            var baseIdx = row * g.TilesX;
            var x = 0;
            while (x < g.TilesX)
            {
                var mark = marks[baseIdx + x];
                if (mark == 0) { x++; continue; }
                var format = (TileFormat)(mark - 1);
                var first = x;
                while (x < g.TilesX && marks[baseIdx + x] == mark) x++;
                var run = new TileRun(row, first, x - first, format);
                switch (format)
                {
                    case TileFormat.Bc7: bc7.Add(run); break;
                    case TileFormat.Bc1: bc1.Add(run); break;
                    default: video.Add(run); break;
                }
            }
        }
        bc7.AddRange(bc1);
        bc7.AddRange(video);
        return bc7;
    }
}

public static class TileFrameWire
{
    public const int MaxChunks = 64;

    /// <summary>Header + optional uncompressed chunk payload (lz4Size=0 means stored).</summary>
    public static byte[] Encode(uint frameIndex, TileGeometry g, IReadOnlyList<TileRun> runs,
        IReadOnlyList<(int rawSize, int lz4Size)> chunks, ReadOnlySpan<byte> chunkData)
    {
        var w = new ByteWriter(32 + runs.Count * 8 + chunks.Count * 8 + chunkData.Length + 16);
        w.U32(frameIndex);
        w.U16((ushort)g.Width);
        w.U16((ushort)g.Height);
        w.U8((byte)g.TileBlocks);
        w.U8((byte)chunks.Count);
        w.U16((ushort)runs.Count);
        foreach (var r in runs)
        {
            w.U16((ushort)r.Row);
            w.U16((ushort)r.First);
            w.U16((ushort)r.Count);
            w.U8((byte)r.Format);
            w.U8(0);
        }
        foreach (var c in chunks)
        {
            w.U32((uint)c.rawSize);
            w.U32((uint)c.lz4Size);
        }
        while (w.Length % 16 != 0)
            w.U8(0);
        w.Bytes(chunkData);
        return w.ToArray();
    }

    /// <summary>Empty frame: presents only (hybrid video layer / keep previous tiles).</summary>
    public static byte[] Empty(uint frameIndex, TileGeometry g) =>
        Encode(frameIndex, g, Array.Empty<TileRun>(), Array.Empty<(int, int)>(), ReadOnlySpan<byte>.Empty);

    /// <summary>
    /// Full-screen video mask. Prefer <see cref="VideoMask"/> with dirty/sticky marks —
    /// full-screen makes still UI look like soft H.264.
    /// </summary>
    public static byte[] VideoPresent(uint frameIndex, TileGeometry g)
    {
        var runs = new List<TileRun>(g.TilesY);
        for (var row = 0; row < g.TilesY; row++)
            runs.Add(new TileRun(row, 0, g.TilesX, TileFormat.Video));
        return Encode(frameIndex, g, runs, Array.Empty<(int, int)>(), ReadOnlySpan<byte>.Empty);
    }

    /// <summary>
    /// Mac-style mask: only marked tiles show the video layer (mark≠0 → .video run).
    /// Unmarked tiles keep prior BC7/mask. Video runs carry no payload.
    /// </summary>
    public static byte[] VideoMask(uint frameIndex, TileGeometry g, ReadOnlySpan<byte> marks)
    {
        if (marks.Length != g.TileCount)
            throw new ArgumentException("marks length must equal tile count", nameof(marks));
        var videoMarks = new byte[marks.Length];
        for (var i = 0; i < marks.Length; i++)
        {
            if (marks[i] != 0)
                videoMarks[i] = (byte)(TileFormat.Video + 1);
        }
        var runs = TileRun.FromMarks(videoMarks, g);
        if (runs.Count == 0)
            return Empty(frameIndex, g);
        return Encode(frameIndex, g, runs, Array.Empty<(int, int)>(), ReadOnlySpan<byte>.Empty);
    }
}

public static class ProbeFlags
{
    public const byte End = 1;
}

public static class TileFlags
{
    public const byte Refinement = 1;
}

public static class VideoWire
{
    public static byte[] Params(VideoCodec codec, IReadOnlyList<byte[]> sets)
    {
        var w = new ByteWriter();
        w.U8(codec == VideoCodec.hevc ? (byte)0 : (byte)1);
        w.U8((byte)sets.Count);
        foreach (var s in sets)
        {
            w.U32((uint)s.Length);
            w.Bytes(s);
        }
        return w.ToArray();
    }

    public static byte[] Frame(bool keyframe, ReadOnlySpan<byte> avcc)
    {
        var w = new ByteWriter(1 + avcc.Length);
        w.U8(keyframe ? (byte)1 : (byte)0);
        w.Bytes(avcc);
        return w.ToArray();
    }
}
