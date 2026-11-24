using Afterscreen.Protocol;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// CPU BC7 mode-6 encoder. Diffs against the previous BGRA frame and only encodes dirty tiles.
/// </summary>
public sealed class CpuTileEncoder : ITileEncoder
{
    private static readonly int[] Weights = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

    public string BackendName => Motion == TileMotion.Bc1 ? "cpu-bc1/bc7" : "cpu-bc7";

    /// <summary>Mac TileEncoder.Motion — dirty tiles as BC1 unless video layer owns them.</summary>
    public TileMotion Motion { get; set; } = TileMotion.Bc1;

    /// <summary>Full compare (ignoring capture dirty rects) at least this often (frames).</summary>
    public int KeyframeInterval
    {
        get => _tracker.AuditInterval;
        set => _tracker.AuditInterval = value;
    }

    // Owns the reference pixels; see TileRefTracker for why this must not alias the capture buffer.
    // Tiles the receiver currently shows as BC1 (lossy). Mac TileEncoder.lossy: they settle to BC7.
    private bool[]? _lossyBc1;

    public bool[] LossyBc1 => _lossyBc1 ?? Array.Empty<bool>();

    private void TrackLossy(byte[] marks)
    {
        if (_lossyBc1 is null || _lossyBc1.Length != marks.Length)
            _lossyBc1 = new bool[marks.Length];
        for (var t = 0; t < marks.Length; t++)
        {
            if (marks[t] == (byte)(TileFormat.Bc1 + 1)) _lossyBc1[t] = true;
            else if (marks[t] == (byte)(TileFormat.Bc7 + 1)) _lossyBc1[t] = false;
        }
    }

    private readonly TileRefTracker _tracker = new();
    private bool _lastForceAll;

    public TileDirtyProbe Probe(byte[] bgra, int width, int height, IReadOnlyList<System.Drawing.Rectangle>? dirty = null)
    {
        var g = new TileGeometry(width, height);
        var changed = _tracker.Compute(bgra, width, height, g, dirty, out var forceAll);
        _lastForceAll = forceAll;
        var count = 0;
        foreach (var c in changed) if (c) count++;
        return new TileDirtyProbe
        {
            DirtyTiles = count,
            TotalTiles = g.TileCount,
            Keyframe = forceAll,
            Marks = TileRefTracker.ToMarks(changed, DirtyMark()),
        };
    }

    public EncodedTileFrame? Encode(byte[] bgra, int width, int height, uint frameIndex)
    {
        var g = new TileGeometry(width, height);
        // Probe normally ran for this frame already; compute here only when it did not.
        if (!_tracker.HasPending)
            Probe(bgra, width, height);
        var forceAll = _lastForceAll;
        var marks = TileRefTracker.ToMarks(_tracker.Changed!, DirtyMark());
        var frame = EncodeMarks(bgra, width, height, frameIndex, marks);
        _tracker.Commit(bgra);
        if (frame is null)
            return null;
        return new EncodedTileFrame
        {
            Payload = frame.Payload,
            DirtyTiles = frame.DirtyTiles,
            TotalTiles = frame.TotalTiles,
            Keyframe = forceAll,
        };
    }

    public EncodedTileFrame? EncodeMarks(byte[] bgra, int width, int height, uint frameIndex, byte[] marks)
    {
        var g = new TileGeometry(width, height);
        if (marks.Length != g.TileCount)
            throw new ArgumentException("marks length must equal tile count", nameof(marks));
        var runs = TileRun.FromMarks(marks, g);
        if (runs.Count == 0)
            return null;
        TrackLossy(marks);

        var dirty = 0;
        foreach (var r in runs) dirty += r.Count;

        var offsets = new int[runs.Count];
        var rawSize = 0;
        for (var i = 0; i < runs.Count; i++)
        {
            offsets[i] = rawSize;
            rawSize += runs[i].Bytes(g);
        }
        var raw = new byte[rawSize];
        // Sequential: Parallel.For + stackalloc EncodeRun correlated with ucrtbase 0xc0000409
        // under scroll; Mac does BC7 on a Metal compute queue instead.
        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];
            var len = run.Bytes(g);
            if (len == 0) continue; // video runs
            EncodeRun(bgra, width, height, g, run, raw.AsSpan(offsets[i], len));
        }

        IReadOnlyList<(int rawSize, int lz4Size)> chunks = raw.Length == 0
            ? Array.Empty<(int rawSize, int lz4Size)>()
            : [(raw.Length, 0)];
        return new EncodedTileFrame
        {
            Payload = TileFrameWire.Encode(frameIndex, g, runs, chunks, raw),
            DirtyTiles = dirty,
            TotalTiles = g.TileCount,
            Keyframe = false,
        };
    }

    public void NotePresented(byte[] bgra)
    {
        // Video layer covered this frame — advance the reference for the tiles that changed so
        // Probe doesn't report a perpetual keyframe (which would lock hybrid on forever).
        _tracker.Commit(bgra);
    }

    public void Reset()
    {
        _tracker.Reset();
        _lossyBc1 = null;
    }

    public void Dispose() => Reset();

    private byte DirtyMark() => Motion switch
    {
        // mark = format+1: BC7=1, BC1=2 (Mac motion=.bc1 on dirty), video=3.
        TileMotion.Bc1 => (byte)(TileFormat.Bc1 + 1),
        TileMotion.Video => (byte)(TileFormat.Video + 1),
        _ => (byte)(TileFormat.Bc7 + 1),
    };

    private static int EncodeRun(byte[] bgra, int width, int height, TileGeometry g, TileRun run, Span<byte> dst)
    {
        var (bw, bh) = run.Blocks(g);
        var originBx = run.First * g.TileBlocks;
        var originBy = run.Row * g.TileBlocks;
        var o = 0;
        Span<byte> indices = stackalloc byte[16];
        Span<(byte r, byte g, byte b, byte a)> px = stackalloc (byte, byte, byte, byte)[16];
        var blockBytes = run.Format == TileFormat.Bc1 ? Bc1.BlockBytes : Bc7.BlockBytes;
        for (var by = 0; by < bh; by++)
        {
            for (var bx = 0; bx < bw; bx++)
            {
                LoadBlock(bgra, width, height, originBx + bx, originBy + by, px);
                if (run.Format == TileFormat.Bc1)
                {
                    Bc1.EncodeBlock(px, dst.Slice(o, Bc1.BlockBytes));
                }
                else
                {
                    EncodeBc7Block(indices, px).CopyTo(dst.Slice(o, Bc7.BlockBytes));
                }
                o += blockBytes;
            }
        }
        return o;
    }

    private static void LoadBlock(
        byte[] bgra, int width, int height, int bx, int by,
        Span<(byte r, byte g, byte b, byte a)> px)
    {
        for (var y = 0; y < 4; y++)
        {
            var py = Math.Min(by * 4 + y, height - 1);
            for (var x = 0; x < 4; x++)
            {
                var pxCoord = Math.Min(bx * 4 + x, width - 1);
                var i = (py * width + pxCoord) * 4;
                px[y * 4 + x] = (bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]);
            }
        }
    }

    private static ReadOnlySpan<byte> EncodeBc7Block(
        Span<byte> indices, Span<(byte r, byte g, byte b, byte a)> px)
    {
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

        if (minL == maxL)
            indices.Clear();
        else
        {
            var dr = e1.r - e0.r;
            var dg = e1.g - e0.g;
            var db = e1.b - e0.b;
            var denom = dr * dr + dg * dg + db * db;
            if (denom == 0)
                indices.Clear();
            else
            {
                for (var i = 0; i < 16; i++)
                {
                    var t = ((px[i].r - e0.r) * dr + (px[i].g - e0.g) * dg + (px[i].b - e0.b) * db) * 64 / denom;
                    t = Math.Clamp(t, 0, 64);
                    var best = 0;
                    var bestErr = int.MaxValue;
                    for (var idx = 0; idx < 16; idx++)
                    {
                        var err = Math.Abs(Weights[idx] - t);
                        if (err < bestErr) { bestErr = err; best = idx; }
                    }
                    indices[i] = (byte)best;
                }
            }
        }

        if (indices[0] >= 8)
        {
            (e0, e1) = (e1, e0);
            for (var i = 0; i < 16; i++)
                indices[i] = (byte)(15 - indices[i]);
        }

        byte p0 = (byte)(e0.r & 1);
        byte p1 = (byte)(e1.r & 1);
        var q0 = ((byte)(e0.r >> 1), (byte)(e0.g >> 1), (byte)(e0.b >> 1), (byte)(e0.a >> 1));
        var q1 = ((byte)(e1.r >> 1), (byte)(e1.g >> 1), (byte)(e1.b >> 1), (byte)(e1.a >> 1));
        return Bc7.MakeMode6(q0, q1, p0, p1, indices);
    }

    /// <summary>Legacy full-frame helper used by tests / capture-once tools.</summary>
    public static byte[] EncodeBc7FullFrame(byte[] bgra, int width, int height)
    {
        var blocksX = (width + 3) / 4;
        var blocksY = (height + 3) / 4;
        var raw = new byte[blocksX * blocksY * Bc7.BlockBytes];
        Parallel.For(0, blocksY, by =>
        {
            Span<byte> indices = stackalloc byte[16];
            Span<(byte r, byte g, byte b, byte a)> px = stackalloc (byte, byte, byte, byte)[16];
            for (var bx = 0; bx < blocksX; bx++)
            {
                LoadBlock(bgra, width, height, bx, by, px);
                EncodeBc7Block(indices, px)
                    .CopyTo(raw.AsSpan((by * blocksX + bx) * Bc7.BlockBytes, Bc7.BlockBytes));
            }
        });
        return raw;
    }

    public static byte[] BuildFullFrameTileMessage(uint frameIndex, int width, int height, byte[] bc7Raw)
    {
        var g = new TileGeometry(width, height);
        var runs = new List<TileRun>(g.TilesY);
        for (var row = 0; row < g.TilesY; row++)
            runs.Add(new TileRun(row, 0, g.TilesX, TileFormat.Bc7));
        var chunks = new List<(int rawSize, int lz4Size)> { (bc7Raw.Length, 0) };
        return TileFrameWire.Encode(frameIndex, g, runs, chunks, bc7Raw);
    }
}
