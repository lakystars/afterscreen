using System.Drawing;
using System.Runtime.InteropServices;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using SharpGen.Runtime;
using Vortice.D3DCompiler;
using Vortice.Direct3D11;
using Vortice.DXGI;
using MapFlags = Vortice.Direct3D11.MapFlags;

namespace Afterscreen.Sender.Encode;

/// <summary>One tile frame as the encoder produced it: the runs and their block data (video runs carry none).</summary>
public sealed class EncodedGpuFrame
{
    public required IReadOnlyList<TileRun> Runs { get; init; }
    /// <summary>Scratch buffer owned by the encoder; valid until its next call.</summary>
    public required byte[] Data { get; init; }
    public required int DataLength { get; init; }

    public int TileCount => Runs.Sum(r => r.Count);

    public byte[] BuildPayload(uint frameIndex, TileGeometry geometry)
        => BuildPayload(frameIndex, geometry, TileCompression.None, out _, out _);

    private const int MaxChunks = 8;
    private const int MinChunkBytes = 256 << 10;

    /// <summary>
    /// Mac <c>TilePacker.pack</c>: the data is split into up to 8 chunks (at least 256 KB each) that are LZ4-compressed
    /// in parallel when asked (a chunk that does not shrink is sent stored, lz4Size 0). <paramref name="lz4In"/> /
    /// <paramref name="lz4Out"/> are the bytes LZ4 was tried on and produced, for <see cref="CompressionPolicy.Record"/>.
    /// </summary>
    public byte[] BuildPayload(uint frameIndex, TileGeometry geometry, TileCompression compression, out int lz4In, out int lz4Out)
    {
        lz4In = lz4Out = 0;
        if (DataLength == 0)
            return TileFrameWire.Encode(frameIndex, geometry, Runs, Array.Empty<(int, int)>(), ReadOnlySpan<byte>.Empty);
        if (compression == TileCompression.None)
            return TileFrameWire.Encode(frameIndex, geometry, Runs, [(DataLength, 0)], Data.AsSpan(0, DataLength));

        var count = Math.Min(MaxChunks, Math.Max(1, DataLength / MinChunkBytes));
        var step = (DataLength / count + 15) / 16 * 16;
        var ranges = new List<(int start, int len)>();
        for (var o = 0; o < DataLength; o += step)
            ranges.Add((o, Math.Min(step, DataLength - o)));
        var tried = compression == TileCompression.All ? ranges.Count : 1;
        var outs = new byte[tried][];
        var sizes = new int[ranges.Count];
        var data = Data;
        Parallel.For(0, tried, i =>
        {
            var (start, len) = ranges[i];
            var buf = new byte[Lz4.Bound(len)];
            var n = Lz4.Compress(data.AsSpan(start, len), buf);
            if (n < len) { outs[i] = buf; sizes[i] = n; }       // else stored
        });
        var chunks = new List<(int, int)>(ranges.Count);
        var payload = new MemoryStream(DataLength);
        for (var i = 0; i < ranges.Count; i++)
        {
            chunks.Add((ranges[i].len, sizes[i]));
            if (i < tried && sizes[i] > 0) payload.Write(outs[i], 0, sizes[i]);
            else payload.Write(data, ranges[i].start, ranges[i].len);
        }
        for (var i = 0; i < tried; i++)
        {
            lz4In += ranges[i].len;
            lz4Out += sizes[i] > 0 ? sizes[i] : ranges[i].len;
        }
        return TileFrameWire.Encode(frameIndex, geometry, Runs, chunks, payload.GetBuffer().AsSpan(0, (int)payload.Length));
    }
}

/// <summary>
/// Port of the Mac Sender's <c>TileEncoder</c> to D3D11 compute. The picture stays in GPU memory
/// (<see cref="GpuFrame"/>), the changed-tile test and the BC7/BC1 compression run on the GPU and only the packed
/// runs are read back. The policy is the Mac one: tiles under the capture's dirty rects plus a rolling refresh
/// slice are candidates; a changed tile is "moving" when it changed again within <see cref="MotionWindow"/> (or is
/// still lossy and has not been still for <see cref="SettleDelay"/>); moving tiles go to the video layer or BC1
/// (BC7 within <see cref="Bc7MotionLimit"/>), tiles that changed after being still go out as BC7, and lossy tiles
/// settle to BC7 once they have been still for <see cref="SettleDelay"/>.
///
/// Deliberate difference from the Mac: Metal encodes BC7 for every candidate tile and diffs the BC7 data. On this
/// GPU that costs ~25-45 ms for a full frame, so the changed-tile test is done on pixels (against a reference
/// texture) and BC7 is only produced for tiles that are actually sent as BC7 (changed-after-still and settling
/// tiles). What is sent is the same.
/// </summary>
public sealed class GpuTileEncoder : IDisposable
{
    /// <summary>Tile changing again within this many seconds counts as moving.</summary>
    public const double MotionWindow = 0.05;
    /// <summary>Link-bound stream: motion window for consecutive-frame changes.</summary>
    public const double CongestedMotionWindow = 0.5;
    /// <summary>Unchanged seconds before a lossy tile's BC7 is sent.</summary>
    public const double SettleDelay = 0.1;
    /// <summary>Full sweep of the rolling refresh slice every this many frames.</summary>
    public const int RefreshFrames = 64;

    private readonly D3dEncodeDevice _dev;
    private readonly ID3D11DeviceContext _ctx;
    private readonly ID3D11ComputeShader _csDiff;
    private readonly ID3D11ComputeShader _csGather;
    private readonly ID3D11Buffer _cb;
    private readonly ID3D11Buffer _candBuf;
    private readonly ID3D11ShaderResourceView _candSrv;
    private readonly ID3D11Buffer _dirtyBuf;
    private readonly ID3D11UnorderedAccessView _dirtyUav;
    private readonly ID3D11Buffer _dirtyStaging;
    private readonly ID3D11Buffer _tableBuf;
    private readonly ID3D11ShaderResourceView _tableSrv;
    private readonly ID3D11Buffer _outBuf;
    private readonly ID3D11UnorderedAccessView _outUav;
    private readonly ID3D11Buffer _outStaging;
    private readonly ID3D11Texture2D _refTex;
    private readonly ID3D11ShaderResourceView _refSrv;
    private bool _refValid;

    // Mac TileEncoder state
    private readonly uint[] _flags;            // per tile: 0 unchanged, else TileFormat + 1
    private readonly uint[] _modes;            // gather mode per tile: 0 BC7, 1 BC7 (settle), 2 BC1, 3 video / reference only
    private readonly bool[] _candMark;
    private readonly uint[] _candList;
    private readonly uint[] _tableData;
    private readonly double[] _lastChange;
    private readonly int[] _lastFrame;
    private readonly bool[] _lossy;
    private readonly bool[] _onVideo;
    private int _encodes;
    private int _refreshCursor;
    private double _lastEncode = double.NegativeInfinity;
    private bool _lastCongested;
    private byte[] _raw = Array.Empty<byte>();

    public TileGeometry Geometry { get; }

    /// <summary>What the receiver shows for tiles in motion.</summary>
    public TileMotion Motion { get; set; } = TileMotion.Bc1;

    /// <summary>Max settled tiles per frame; keeps a big refinement from stalling motion. Video mode: also the BC7 cap for a frame's changed still tiles.</summary>
    public int SettleLimit { get; set; } = int.MaxValue;

    /// <summary>BC1 motion path: max moving tiles per frame kept as BC7; beyond it all moving tiles go out as BC1.</summary>
    public int Bc7MotionLimit { get; set; }

    /// <summary>Tiles the receiver shows lossy: BC1, or the video layer.</summary>
    public int LossyTiles { get; private set; }

    /// <summary>Tiles that differ from the reference in the last frame (video-carried ones too).</summary>
    public int ChangedTiles { get; private set; }

    /// <summary>Last <see cref="Encode"/>: tiles classified still vs moving (diagnostic <c>cls[]</c>).</summary>
    public int LastStill { get; private set; }
    public int LastMoving { get; private set; }
    /// <summary>Last <see cref="Encode"/> / <see cref="Refine"/>: tile runs as BC7 / BC1 / video (diagnostic <c>fmt[]</c>).</summary>
    public int LastFmtBc7 { get; private set; }
    public int LastFmtBc1 { get; private set; }
    public int LastFmtVideo { get; private set; }

    /// <summary>True while the receiver shows tile <paramref name="tile"/> as BC1 or from the video layer.</summary>
    public bool IsLossy(int tile) => _lossy[tile];

    public string BackendName { get; }

    private GpuTileEncoder(D3dEncodeDevice device, TileGeometry geometry)
    {
        _dev = device;
        _ctx = device.Context;
        Geometry = geometry;
        BackendName = $"d3d11-tiles:{device.Adapter.Description}";
        var tc = geometry.TileCount;
        _flags = new uint[tc];
        _modes = new uint[tc];
        _candMark = new bool[tc];
        _candList = new uint[tc];
        _tableData = new uint[tc * 4];
        _lastChange = Enumerable.Repeat(double.NegativeInfinity, tc).ToArray();
        _lastFrame = Enumerable.Repeat(-2, tc).ToArray();
        _lossy = new bool[tc];
        _onVideo = new bool[tc];

        _csDiff = CompileEntry("tileDiffPix");
        _csGather = CompileEntry("tileGather");
        var d = device.Device;
        _cb = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = 32,
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ConstantBuffer,
            CPUAccessFlags = CpuAccessFlags.Write,
        });
        _candBuf = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)(tc * 4),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write,
            StructureByteStride = 4,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _candSrv = d.CreateShaderResourceView(_candBuf);
        _dirtyBuf = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)(tc * 4),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess,
            StructureByteStride = 4,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _dirtyUav = d.CreateUnorderedAccessView(_dirtyBuf);
        _dirtyStaging = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)(tc * 4),
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
        _tableBuf = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)(tc * 16),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write,
            StructureByteStride = 16,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _tableSrv = d.CreateShaderResourceView(_tableBuf);
        var outBytes = (uint)((long)geometry.BlocksX * geometry.BlocksY * 16);
        _outBuf = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = outBytes,
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess,
            StructureByteStride = 8,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _outUav = d.CreateUnorderedAccessView(_outBuf);
        _outStaging = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = outBytes,
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
        _refTex = d.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)geometry.Width,
            Height = (uint)geometry.Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource,
        });
        _refSrv = d.CreateShaderResourceView(_refTex);
    }

    public static GpuTileEncoder? TryCreate(D3dEncodeDevice device, int width, int height)
    {
        try
        {
            return new GpuTileEncoder(device, new TileGeometry(width, height));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[gpu-tiles] init failed: {ex.Message}");
            return null;
        }
    }

    private ID3D11ComputeShader CompileEntry(string entry)
    {
        try
        {
            var bytecode = Compiler.Compile(TileEncoderHlsl.Source, entry, "TileEncoder.hlsl", "cs_5_0",
                ShaderFlags.OptimizationLevel3);
            return _dev.Device.CreateComputeShader(bytecode.Span);
        }
        catch (SharpGenException ex)
        {
            throw new InvalidOperationException($"HLSL compile failed for {entry}: {ex.Message}", ex);
        }
    }

    // ------------------------------------------------------------------ encode

    /// <summary>
    /// Mac <c>TileEncoder.encode</c>. <paramref name="dirty"/>: capture's changed regions in stream pixels, null
    /// encodes all; <paramref name="congested"/>: the stream lags its source; <paramref name="start"/>: a stream's
    /// first keyframe, which may go by video. Null when there is nothing to send.
    /// </summary>
    public EncodedGpuFrame? Encode(GpuFrame frame, bool forceAll, IReadOnlyList<Rectangle>? dirty, double now,
        bool congested = false, bool start = false)
    {
        lock (_dev.ContextLock)
            return EncodeLocked(frame, forceAll, dirty, now, congested, start);
    }

    private EncodedGpuFrame? EncodeLocked(GpuFrame frame, bool forceAll, IReadOnlyList<Rectangle>? dirty, double now,
        bool congested, bool start)
    {
        var g = Geometry;
        var tc = g.TileCount;
        ChangedTiles = 0;

        // Candidates: tiles under the dirty rects plus a rolling refresh slice; every tile when forced / unknown.
        var count = 0;
        var all = forceAll || dirty is null || !_refValid;
        if (all)
        {
            for (var t = 0; t < tc; t++) _candList[count++] = (uint)t;
        }
        else
        {
            Array.Clear(_candMark);
            MarkTilesUnder(dirty!, _candMark);
            var slice = Math.Max(1, (tc + RefreshFrames - 1) / RefreshFrames);
            for (var i = 0; i < slice; i++) _candMark[(_refreshCursor + i) % tc] = true;
            _refreshCursor = (_refreshCursor + slice) % tc;
            for (var t = 0; t < tc; t++)
                if (_candMark[t]) _candList[count++] = (uint)t;
        }

        Array.Clear(_flags);
        if (forceAll || !_refValid)
            Array.Fill(_flags, 1u);                 // no reference yet / forced: everything counts as changed
        else
            RunDiff(frame, count);

        _encodes++;
        // Gap after an uncongested frame means pause, not slow link; full frames count as congested.
        var congestedWindow = _lastCongested
            ? Math.Max(CongestedMotionWindow, 1.5 * (now - _lastEncode))
            : CongestedMotionWindow;
        _lastEncode = now;
        _lastCongested = congested || forceAll;

        var settling = new List<int>();
        var entering = new List<int>();
        var referenceOnly = new List<int>();
        var moving = new List<int>();
        var still = new List<int>();
        var changed = 0;
        for (var t = 0; t < tc; t++)
        {
            if (_flags[t] != 0)
            {
                changed++;
                var since = now - _lastChange[t];
                // A lossy tile counts as moving until it has been still for SettleDelay.
                var inMotion = !forceAll && (since < MotionWindow || (_lossy[t] && since < SettleDelay)
                    || (congested && _lastFrame[t] == _encodes - 1 && since < congestedWindow));
                _lastChange[t] = now;
                _lastFrame[t] = _encodes;
                if (inMotion && Motion == TileMotion.Video)
                {
                    ToVideo(t, entering, referenceOnly);
                    continue;
                }
                if (inMotion) moving.Add(t);
                else still.Add(t);
            }
            else if (_lossy[t] && now - _lastChange[t] >= SettleDelay && settling.Count < SettleLimit)
            {
                settling.Add(t);
                Mark(t, 1);
            }
        }

        // Video path: a change past the settle budget goes by video; its tiles settle to BC7 within the budget later.
        // A requested keyframe stays BC7: it recovers a failing decoder.
        var viaVideo = Motion == TileMotion.Video && (!forceAll || start) && still.Count > SettleLimit;
        foreach (var t in still)
        {
            if (viaVideo)
            {
                ToVideo(t, entering, referenceOnly);
            }
            else
            {
                _lossy[t] = false;
                _onVideo[t] = false;
                Mark(t, 0);
            }
        }

        // Motion within the link's BC7 budget stays BC7; past it all moving tiles drop to BC1.
        var sharp = moving.Count <= Bc7MotionLimit;
        foreach (var t in moving)
        {
            _lossy[t] = !sharp;
            _onVideo[t] = false;
            Mark(t, sharp ? 0u : 2u);
        }

        var frameOut = Gather(frame, referenceOnly, forceAll);
        if (frameOut is not null)
        {
            foreach (var t in entering)
            {
                _lossy[t] = true;
                _onVideo[t] = true;
            }
        }
        ChangedTiles = changed;
        LastStill = still.Count;
        LastMoving = moving.Count;
        TallyFormats(frameOut);
        return Settle(settling, frameOut);
    }

    /// <summary>Mac <c>refine</c>: BC7 of tiles that have been still for SettleDelay; null when none.</summary>
    public EncodedGpuFrame? Refine(GpuFrame frame, double now)
    {
        lock (_dev.ContextLock)
            return RefineLocked(frame, now);
    }

    private EncodedGpuFrame? RefineLocked(GpuFrame frame, double now)
    {
        Array.Clear(_flags);
        LastStill = LastMoving = 0;
        var settling = new List<int>();
        for (var t = 0; t < Geometry.TileCount && settling.Count < SettleLimit; t++)
            if (_lossy[t] && now - _lastChange[t] >= SettleDelay)
                settling.Add(t);
        foreach (var t in settling) Mark(t, 1);
        if (settling.Count == 0)
        {
            LastFmtBc7 = LastFmtBc1 = LastFmtVideo = 0;
            return null;
        }
        var refined = Settle(settling, Gather(frame, new List<int>(), false));
        TallyFormats(refined);
        return refined;
    }

    private void TallyFormats(EncodedGpuFrame? frame)
    {
        LastFmtBc7 = LastFmtBc1 = LastFmtVideo = 0;
        if (frame is null) return;
        foreach (var run in frame.Runs)
        {
            switch (run.Format)
            {
                case TileFormat.Bc7: LastFmtBc7 += run.Count; break;
                case TileFormat.Bc1: LastFmtBc1 += run.Count; break;
                case TileFormat.Video: LastFmtVideo += run.Count; break;
            }
        }
    }

    /// <summary>Seconds until the next lossy tile settles; null if none.</summary>
    public double? NextRefinement(double now)
    {
        double? soonest = null;
        for (var t = 0; t < Geometry.TileCount; t++)
        {
            if (!_lossy[t]) continue;
            var due = Math.Max(0, _lastChange[t] + SettleDelay - now);
            soonest = soonest is null ? due : Math.Min(soonest.Value, due);
        }
        return soonest;
    }

    /// <summary>The receiver may have missed frames: every tile goes again, as BC7, over the next refinements.</summary>
    public void ResyncAll()
    {
        for (var t = 0; t < Geometry.TileCount; t++)
        {
            _lossy[t] = true;
            _onVideo[t] = false;
        }
        LossyTiles = Geometry.TileCount;
    }

    /// <summary>The next frame is treated as the first one: no reference, every tile changed.</summary>
    public void Reset()
    {
        _refValid = false;
        Array.Clear(_lossy);
        Array.Clear(_onVideo);
        LossyTiles = 0;
    }

    // ------------------------------------------------------------------ policy helpers

    /// <summary>Video tiles become lossy once a frame carries their run.</summary>
    private void ToVideo(int t, List<int> entering, List<int> referenceOnly)
    {
        if (_onVideo[t])
        {
            _flags[t] = 0;
            _modes[t] = 3;
            referenceOnly.Add(t);
        }
        else
        {
            Mark(t, 3);
            entering.Add(t);
        }
    }

    private void Mark(int tile, uint mode)
    {
        _modes[tile] = mode;
        var format = mode == 2 ? TileFormat.Bc1 : (mode == 3 ? TileFormat.Video : TileFormat.Bc7);
        _flags[tile] = (uint)format + 1u;
    }

    /// <summary>Settling tiles stay lossy until a frame carries their BC7.</summary>
    private EncodedGpuFrame? Settle(List<int> tiles, EncodedGpuFrame? frame)
    {
        if (frame is not null)
        {
            foreach (var t in tiles)
            {
                _lossy[t] = false;
                _onVideo[t] = false;
            }
        }
        var lossy = 0;
        foreach (var l in _lossy) if (l) lossy++;
        LossyTiles = lossy;
        return frame;
    }

    private void MarkTilesUnder(IReadOnlyList<Rectangle> rects, bool[] marks)
    {
        var g = Geometry;
        var size = g.TilePixels;
        foreach (var rect in rects)
        {
            var r = Rectangle.Intersect(rect, new Rectangle(0, 0, g.Width, g.Height));
            if (r.Width <= 0 || r.Height <= 0) continue;
            var x0 = r.Left / size;
            var x1 = (r.Right + size - 1) / size - 1;
            var y0 = r.Top / size;
            var y1 = (r.Bottom + size - 1) / size - 1;
            for (var y = y0; y <= y1; y++)
                for (var x = x0; x <= x1; x++)
                    marks[y * g.TilesX + x] = true;
        }
    }

    // ------------------------------------------------------------------ GPU passes

    private unsafe void WriteBuffer(ID3D11Buffer buffer, uint[] data, int uints)
    {
        var m = _ctx.Map(buffer, MapMode.WriteDiscard, MapFlags.None);
        fixed (uint* p = data)
            Buffer.MemoryCopy(p, (void*)m.DataPointer, (long)uints * 4, (long)uints * 4);
        _ctx.Unmap(buffer);
    }

    private void SetParams(int candidates)
    {
        var g = Geometry;
        var m = _ctx.Map(_cb, MapMode.WriteDiscard, MapFlags.None);
        Marshal.WriteInt32(m.DataPointer, 0, g.Width);
        Marshal.WriteInt32(m.DataPointer, 4, g.Height);
        Marshal.WriteInt32(m.DataPointer, 8, g.BlocksX);
        Marshal.WriteInt32(m.DataPointer, 12, g.BlocksY);
        Marshal.WriteInt32(m.DataPointer, 16, g.TilesX);
        Marshal.WriteInt32(m.DataPointer, 20, g.TileBlocks);
        Marshal.WriteInt32(m.DataPointer, 24, g.TileCount);
        Marshal.WriteInt32(m.DataPointer, 28, candidates);
        _ctx.Unmap(_cb);
    }

    /// <summary>tileDiff: flags candidate tiles whose pixels differ from the reference texture.</summary>
    private void RunDiff(GpuFrame frame, int count)
    {
        if (count == 0)
            return;
        WriteBuffer(_candBuf, _candList, count);
        SetParams(count);
        _ctx.CSSetShader(_csDiff);
        _ctx.CSSetConstantBuffer(0, _cb);
        _ctx.CSSetShaderResource(0, frame.Srv);
        _ctx.CSSetShaderResource(1, _refSrv);
        _ctx.CSSetShaderResource(2, _candSrv);
        _ctx.CSSetUnorderedAccessView(1, _dirtyUav);
        _ctx.Dispatch((uint)count, 1, 1);
        _ctx.CSSetUnorderedAccessView(1, (ID3D11UnorderedAccessView?)null!);
        _ctx.CSSetShaderResource(0, (ID3D11ShaderResourceView?)null!);
        _ctx.CSSetShaderResource(1, (ID3D11ShaderResourceView?)null!);
        _ctx.CSSetShaderResource(2, (ID3D11ShaderResourceView?)null!);
        _ctx.CSSetConstantBuffer(0, (ID3D11Buffer?)null!);
        _ctx.CSSetShader(null);

        _ctx.CopyResource(_dirtyStaging, _dirtyBuf);
        _ctx.Flush();
        var m = _ctx.Map(_dirtyStaging, MapMode.Read, MapFlags.None);
        try
        {
            for (var i = 0; i < count; i++)
            {
                var t = (int)_candList[i];
                _flags[t] = (uint)Marshal.ReadInt32(m.DataPointer, t * 4) != 0 ? 1u : 0u;
            }
        }
        finally
        {
            _ctx.Unmap(_dirtyStaging);
        }
    }

    /// <summary>
    /// Mac <c>gather</c>: runs from the marks, one GPU pass that writes BC7 / BC1 blocks in run order, then the
    /// reference texture follows every tile that changed. <paramref name="referenceOnly"/> tiles (video tiles
    /// already on the video layer) only update the reference. Null when there is no run to send.
    /// </summary>
    private EncodedGpuFrame? Gather(GpuFrame frame, List<int> referenceOnly, bool full)
    {
        var g = Geometry;
        var tc = g.TileCount;
        var marks = new byte[tc];
        for (var t = 0; t < tc; t++) marks[t] = (byte)_flags[t];
        var runs = TileRun.FromMarks(marks, g);
        if (runs.Count == 0 && referenceOnly.Count == 0)
            return null;

        // Per tile: index, first output unit (8 bytes), run width in blocks, gather mode.
        var entries = 0;
        var outUnits = 0;
        foreach (var run in runs)
        {
            var (bw, bh) = run.Blocks(g);
            var units = run.Format == TileFormat.Bc1 ? 1 : (run.Format == TileFormat.Bc7 ? 2 : 0);
            if (units > 0)
            {
                for (var t = 0; t < run.Count; t++)
                {
                    var tile = run.Row * g.TilesX + run.First + t;
                    _tableData[entries * 4] = (uint)tile;
                    _tableData[entries * 4 + 1] = (uint)(outUnits + t * g.TileBlocks * units);
                    _tableData[entries * 4 + 2] = (uint)bw;
                    _tableData[entries * 4 + 3] = _modes[tile];
                    entries++;
                }
            }
            outUnits += bw * bh * units;
        }

        if (entries > 0)
        {
            WriteBuffer(_tableBuf, _tableData, entries * 4);
            SetParams(entries);
            _ctx.CSSetShader(_csGather);
            _ctx.CSSetConstantBuffer(0, _cb);
            _ctx.CSSetShaderResource(0, frame.Srv);
            _ctx.CSSetShaderResource(3, _tableSrv);
            _ctx.CSSetUnorderedAccessView(0, _outUav);
            var groups = (uint)((g.TileBlocks + 7) / 8);
            _ctx.Dispatch(groups, groups, (uint)entries);
            _ctx.CSSetUnorderedAccessView(0, (ID3D11UnorderedAccessView?)null!);
            _ctx.CSSetShaderResource(0, (ID3D11ShaderResourceView?)null!);
            _ctx.CSSetShaderResource(3, (ID3D11ShaderResourceView?)null!);
            _ctx.CSSetConstantBuffer(0, (ID3D11Buffer?)null!);
            _ctx.CSSetShader(null);
        }

        // Reference follows every tile sent as BC7/BC1 or carried by video (not settling tiles: they did not change).
        var follow = new List<int>(referenceOnly);
        for (var t = 0; t < tc; t++)
            if (_flags[t] != 0 && _modes[t] != 1) follow.Add(t);
        UpdateReference(frame, follow, full || !_refValid);
        _refValid = true;

        var dataLength = outUnits * 8;
        if (dataLength > 0)
        {
            if (_raw.Length < dataLength) _raw = new byte[dataLength];
            _ctx.CopySubresourceRegion(_outStaging, 0, 0, 0, 0, _outBuf, 0,
                new Vortice.Mathematics.Box(0, 0, 0, dataLength, 1, 1));
            _ctx.Flush();
            var m = _ctx.Map(_outStaging, MapMode.Read, MapFlags.None);
            try { Marshal.Copy(m.DataPointer, _raw, 0, dataLength); }
            finally { _ctx.Unmap(_outStaging); }
        }

        if (runs.Count == 0)
            return null;
        return new EncodedGpuFrame { Runs = runs, Data = _raw, DataLength = dataLength };
    }

    /// <summary>Copies the given tiles (row runs merged into one box) from the frame to the reference texture.</summary>
    private void UpdateReference(GpuFrame frame, List<int> tiles, bool whole)
    {
        var g = Geometry;
        if (whole || tiles.Count >= g.TileCount)
        {
            _ctx.CopyResource(_refTex, frame.Texture);
            return;
        }
        if (tiles.Count == 0)
            return;
        tiles.Sort();
        var px = g.TilePixels;
        var i = 0;
        while (i < tiles.Count)
        {
            var row = tiles[i] / g.TilesX;
            var first = tiles[i] % g.TilesX;
            var last = first;
            var j = i + 1;
            while (j < tiles.Count && tiles[j] / g.TilesX == row && tiles[j] % g.TilesX == last + 1)
            {
                last++;
                j++;
            }
            var x0 = first * px;
            var y0 = row * px;
            var x1 = Math.Min((last + 1) * px, g.Width);
            var y1 = Math.Min((row + 1) * px, g.Height);
            _ctx.CopySubresourceRegion(_refTex, 0, (uint)x0, (uint)y0, 0, frame.Texture, 0,
                new Vortice.Mathematics.Box(x0, y0, 0, x1, y1, 1));
            i = j;
        }
    }

    public void Dispose()
    {
        _refSrv.Dispose();
        _refTex.Dispose();
        _outStaging.Dispose();
        _outUav.Dispose();
        _outBuf.Dispose();
        _tableSrv.Dispose();
        _tableBuf.Dispose();
        _dirtyStaging.Dispose();
        _dirtyUav.Dispose();
        _dirtyBuf.Dispose();
        _candSrv.Dispose();
        _candBuf.Dispose();
        _cb.Dispose();
        _csGather.Dispose();
        _csDiff.Dispose();
    }
}
