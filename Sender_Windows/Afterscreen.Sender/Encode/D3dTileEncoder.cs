using System.Runtime.InteropServices;
using Afterscreen.Protocol;
using SharpGen.Runtime;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using MapFlags = Vortice.Direct3D11.MapFlags;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// D3D11 compute BC7 (Mac Metal <c>bc7Encode</c>). Dirty detect stays CPU; BC1 runs stay CPU.
/// </summary>
public sealed class D3dTileEncoder : ITileEncoder
{
    private readonly D3dEncodeDevice _device;
    private readonly bool _ownsDevice;
    private readonly ID3D11ComputeShader _cs;
    private readonly ID3D11Buffer _paramsCb;
    private readonly ID3D11Buffer _tilesBuf;
    private readonly ID3D11ShaderResourceView _tilesSrv;
    private readonly ID3D11Buffer _outBuf;
    private readonly ID3D11UnorderedAccessView _outUav;
    private readonly ID3D11Buffer _outStaging;
    private ID3D11Texture2D? _srcTex;
    private ID3D11ShaderResourceView? _srcSrv;
    private int _texW, _texH;

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
    private readonly int _maxBatch;
    private readonly uint[] _tileList;
    private readonly byte[] _outScratch;
    private byte[]? _rawScratch;

    public string BackendName { get; }
    public TileMotion Motion { get; set; } = TileMotion.Bc1;
    public int KeyframeInterval
    {
        get => _tracker.AuditInterval;
        set => _tracker.AuditInterval = value;
    }
    /// <summary>True — hybrid settle can use a Mac-sized BC7 budget.</summary>
    public bool SupportsFastSettle => true;

    private D3dTileEncoder(D3dEncodeDevice device, bool ownsDevice, int width, int height)
    {
        _device = device;
        _ownsDevice = ownsDevice;
        BackendName = $"d3d11-bc7:{device.Adapter.Description}";

        var g = new TileGeometry(width, height);
        _maxBatch = Math.Min(64, Math.Max(1, g.TileCount));
        var batchBlocks = _maxBatch * g.TileBlocks * g.TileBlocks;
        _tileList = new uint[g.TileCount];
        _outScratch = new byte[g.TileCount * g.TileBlocks * g.TileBlocks * 16];

        ReadOnlyMemory<byte> bytecode;
        try
        {
            bytecode = Compiler.Compile(
                Bc7EncodeHlsl.Source, "bc7Encode", "Bc7Encode.hlsl", "cs_5_0",
                ShaderFlags.OptimizationLevel3);
        }
        catch (SharpGenException ex)
        {
            throw new InvalidOperationException("BC7 HLSL compile failed: " + ex.Message, ex);
        }

        _cs = device.Device.CreateComputeShader(bytecode.Span);
        _paramsCb = device.Device.CreateBuffer(new BufferDescription
        {
            ByteWidth = 32,
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ConstantBuffer,
            CPUAccessFlags = CpuAccessFlags.Write,
        });

        var tilesBytes = (uint)(_maxBatch * 4);
        _tilesBuf = device.Device.CreateBuffer(new BufferDescription
        {
            ByteWidth = tilesBytes,
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write,
            StructureByteStride = 4,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _tilesSrv = device.Device.CreateShaderResourceView(_tilesBuf);

        var outBytes = (uint)(batchBlocks * 16);
        _outBuf = device.Device.CreateBuffer(new BufferDescription
        {
            ByteWidth = outBytes,
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess | BindFlags.ShaderResource,
            StructureByteStride = 16,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _outUav = device.Device.CreateUnorderedAccessView(_outBuf);
        _outStaging = device.Device.CreateBuffer(new BufferDescription
        {
            ByteWidth = outBytes,
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
    }

    public static D3dTileEncoder? TryCreate(
        GpuAdapterInfo? adapter, int width, int height, D3dEncodeDevice? shared = null)
    {
        var owns = shared is null;
        var device = shared ?? D3dEncodeDevice.TryCreate(adapter);
        if (device is null)
            return null;
        try
        {
            return new D3dTileEncoder(device, owns, width, height);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[d3d-bc7] init failed: {ex.Message}");
            if (owns)
                device.Dispose();
            return null;
        }
    }

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

        var candidateCount = 0;
        for (var t = 0; t < marks.Length; t++)
        {
            if (marks[t] == (byte)(TileFormat.Bc7 + 1))
                _tileList[candidateCount++] = (uint)t;
        }

        // Video-only / BC1-only: no full-frame GPU upload (was copying 18MB BGRA every hybrid frame).
        if (candidateCount > 0)
        {
            EnsureSource(width, height);
            UploadBgra(bgra, width, height);
            for (var off = 0; off < candidateCount; off += _maxBatch)
            {
                var n = Math.Min(_maxBatch, candidateCount - off);
                DispatchBc7Batch(g, off, n);
                ReadbackBatch(g, off, n);
            }
        }

        var dirty = 0;
        foreach (var r in runs) dirty += r.Count;

        var offsets = new int[runs.Count];
        var rawSize = 0;
        for (var i = 0; i < runs.Count; i++)
        {
            offsets[i] = rawSize;
            rawSize += runs[i].Bytes(g);
        }
        var raw = RentRaw(rawSize);

        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];
            var len = run.Bytes(g);
            if (len == 0) continue;
            var dst = raw.AsSpan(offsets[i], len);
            if (run.Format == TileFormat.Bc7)
                CopyBc7Run(g, run, dst);
            else if (run.Format == TileFormat.Bc1)
                EncodeBc1Run(bgra, width, height, g, run, dst);
        }

        IReadOnlyList<(int rawSize, int lz4Size)> chunks = rawSize == 0
            ? Array.Empty<(int, int)>()
            : [(rawSize, 0)];
        return new EncodedTileFrame
        {
            Payload = TileFrameWire.Encode(frameIndex, g, runs, chunks, raw.AsSpan(0, rawSize)),
            DirtyTiles = dirty,
            TotalTiles = g.TileCount,
            Keyframe = false,
        };
    }

    public void NotePresented(byte[] bgra)
    {
        // Advance the reference for changed tiles only (a full BlockCopy per hybrid frame
        // stalled the pump).
        _tracker.Commit(bgra);
    }

    public void Reset()
    {
        _tracker.Reset();
        _lossyBc1 = null;
    }

    private byte[] RentRaw(int size)
    {
        if (size <= 0) return Array.Empty<byte>();
        if (_rawScratch is null || _rawScratch.Length < size)
            _rawScratch = new byte[size];
        return _rawScratch;
    }

    public void Dispose()
    {
        _srcSrv?.Dispose();
        _srcTex?.Dispose();
        _outStaging.Dispose();
        _outUav.Dispose();
        _outBuf.Dispose();
        _tilesSrv.Dispose();
        _tilesBuf.Dispose();
        _paramsCb.Dispose();
        _cs.Dispose();
        if (_ownsDevice)
            _device.Dispose();
    }

    private void EnsureSource(int width, int height)
    {
        if (_srcTex is not null && _texW == width && _texH == height)
            return;
        _srcSrv?.Dispose();
        _srcTex?.Dispose();
        _texW = width;
        _texH = height;
        _srcTex = _device.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource,
        });
        _srcSrv = _device.Device.CreateShaderResourceView(_srcTex);
    }

    private void UploadBgra(byte[] bgra, int width, int height)
    {
        var ctx = _device.Context;
        var handle = GCHandle.Alloc(bgra, GCHandleType.Pinned);
        try
        {
            var box = new Vortice.Mathematics.Box(0, 0, 0, width, height, 1);
            ctx.UpdateSubresource(_srcTex!, 0, box, handle.AddrOfPinnedObject(), (uint)(width * 4), 0);
        }
        finally
        {
            handle.Free();
        }
    }

    private void DispatchBc7Batch(TileGeometry g, int listOffset, int batchCount)
    {
        var ctx = _device.Context;
        var mapped = ctx.Map(_tilesBuf, MapMode.WriteDiscard, MapFlags.None);
        for (var i = 0; i < batchCount; i++)
            Marshal.WriteInt32(mapped.DataPointer, i * 4, unchecked((int)_tileList[listOffset + i]));
        ctx.Unmap(_tilesBuf);

        mapped = ctx.Map(_paramsCb, MapMode.WriteDiscard, MapFlags.None);
        Marshal.WriteInt32(mapped.DataPointer, 0, g.Width);
        Marshal.WriteInt32(mapped.DataPointer, 4, g.Height);
        Marshal.WriteInt32(mapped.DataPointer, 8, g.BlocksX);
        Marshal.WriteInt32(mapped.DataPointer, 12, g.BlocksY);
        Marshal.WriteInt32(mapped.DataPointer, 16, g.TilesX);
        Marshal.WriteInt32(mapped.DataPointer, 20, g.TileBlocks);
        Marshal.WriteInt32(mapped.DataPointer, 24, g.TileCount);
        Marshal.WriteInt32(mapped.DataPointer, 28, batchCount);
        ctx.Unmap(_paramsCb);

        ctx.CSSetShader(_cs);
        ctx.CSSetConstantBuffer(0, _paramsCb);
        ctx.CSSetShaderResource(0, _srcSrv);
        ctx.CSSetShaderResource(1, _tilesSrv);
        ctx.CSSetUnorderedAccessView(0, _outUav);

        var gx = (uint)((g.TileBlocks + 7) / 8);
        var gy = (uint)((g.TileBlocks + 7) / 8);
        ctx.Dispatch(gx, gy, (uint)batchCount);

        ctx.CSSetUnorderedAccessView(0, (ID3D11UnorderedAccessView?)null!);
        ctx.CSSetShaderResource(0, (ID3D11ShaderResourceView?)null!);
        ctx.CSSetShaderResource(1, (ID3D11ShaderResourceView?)null!);
        ctx.CSSetConstantBuffer(0, (ID3D11Buffer?)null!);
        ctx.CSSetShader(null);
    }

    /// <summary>Dense batch UAV → tile-major scratch (only this batch's tiles).</summary>
    private void ReadbackBatch(TileGeometry g, int listOffset, int batchCount)
    {
        var ctx = _device.Context;
        ctx.CopyResource(_outStaging, _outBuf);
        ctx.Flush();
        var mapped = ctx.Map(_outStaging, MapMode.Read, MapFlags.None);
        try
        {
            var tileBytes = g.TileBlocks * g.TileBlocks * 16;
            for (var i = 0; i < batchCount; i++)
            {
                var tile = (int)_tileList[listOffset + i];
                Marshal.Copy(mapped.DataPointer + i * tileBytes, _outScratch, tile * tileBytes, tileBytes);
            }
        }
        finally
        {
            ctx.Unmap(_outStaging);
        }
    }

    private void CopyBc7Run(TileGeometry g, TileRun run, Span<byte> dst)
    {
        var (bw, bh) = run.Blocks(g);
        var originBx = run.First * g.TileBlocks;
        var originBy = run.Row * g.TileBlocks;
        var o = 0;
        for (var by = 0; by < bh; by++)
        {
            for (var bx = 0; bx < bw; bx++)
            {
                var absBx = originBx + bx;
                var absBy = originBy + by;
                var tile = (absBy / g.TileBlocks) * g.TilesX + absBx / g.TileBlocks;
                var local = (absBy % g.TileBlocks) * g.TileBlocks + absBx % g.TileBlocks;
                var srcOff = (tile * g.TileBlocks * g.TileBlocks + local) * 16;
                _outScratch.AsSpan(srcOff, 16).CopyTo(dst.Slice(o, 16));
                o += 16;
            }
        }
    }

    private static void EncodeBc1Run(
        byte[] bgra, int width, int height, TileGeometry g, TileRun run, Span<byte> dst)
    {
        var (bw, bh) = run.Blocks(g);
        var originBx = run.First * g.TileBlocks;
        var originBy = run.Row * g.TileBlocks;
        var o = 0;
        Span<(byte r, byte g, byte b, byte a)> px = stackalloc (byte, byte, byte, byte)[16];
        for (var by = 0; by < bh; by++)
        {
            for (var bx = 0; bx < bw; bx++)
            {
                LoadBlock(bgra, width, height, originBx + bx, originBy + by, px);
                Bc1.EncodeBlock(px, dst.Slice(o, Bc1.BlockBytes));
                o += Bc1.BlockBytes;
            }
        }
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

    private byte DirtyMark() => Motion switch
    {
        // Mac TileEncoder: motion=.video → dirty tiles are video runs (no BC7 upload).
        TileMotion.Bc1 => (byte)(TileFormat.Bc1 + 1),
        TileMotion.Video => (byte)(TileFormat.Video + 1),
        _ => (byte)(TileFormat.Bc7 + 1),
    };
}
