using System.Drawing;
using System.Runtime.InteropServices;
using Afterscreen.Sender.Encode;
using Vortice;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Afterscreen.Sender.Capture;

public sealed class CapturedFrame
{
    public required int Width { get; init; }
    public required int Height { get; init; }
    private byte[]? _bgra;
    private Func<byte[]>? _cpuProvider;

    /// <summary>
    /// CPU copy of the picture: a persistent buffer, updated in place for the dirty regions only. On the GPU
    /// path it is produced lazily - only the regions changed since the last read are copied out, and only when
    /// something needs system memory (the video encoder, a CPU tile encoder).
    /// </summary>
    public byte[] Bgra { get => _cpuProvider is null ? _bgra! : _cpuProvider(); init => _bgra = value; }
    public Func<byte[]>? CpuProvider { init => _cpuProvider = value; }

    /// <summary>
    /// The picture in GPU memory (the Mac Sender wraps the ScreenCaptureKit pixel buffer as an MTLTexture the
    /// same way). Persistent texture: it always holds the latest capture. Null on the CPU path.
    /// </summary>
    public GpuFrame? Gpu { get; init; }
    public long TimestampQpc { get; init; }

    /// <summary>
    /// Regions changed since the previously processed frame, in frame pixels; null = unknown
    /// (treat as whole frame). Mac: <c>CapturedFrame.dirty</c>.
    /// </summary>
    public IReadOnlyList<Rectangle>? Dirty { get; set; }

    /// <summary>Mac <c>CapturedFrame.maxRegions</c>: more merged regions than this = unknown.</summary>
    public const int MaxRegions = 256;

    /// <summary>
    /// A frame replacing an unsent one carries both frames' regions
    /// (Mac <c>CapturedFrame.merge</c>); either side unknown or too many → unknown.
    /// </summary>
    public static IReadOnlyList<Rectangle>? Merge(IReadOnlyList<Rectangle>? dropped, IReadOnlyList<Rectangle>? newer)
    {
        if (dropped is null || newer is null || dropped.Count + newer.Count > MaxRegions)
            return null;
        var merged = new List<Rectangle>(dropped.Count + newer.Count);
        merged.AddRange(newer);
        merged.AddRange(dropped);
        return merged;
    }
}

/// <summary>
/// DXGI Desktop Duplication → BGRA at the target size (CPU nearest scale). Only the regions DXGI
/// reports dirty are copied out of the GPU staging texture and scaled; frames with no desktop
/// change (pointer-only) are skipped, like Mac ScreenCaptureKit skipping frames without content.
/// </summary>
public sealed class DxgiCapture : IDisposable
{
    private ID3D11Device _device = null!;
    private ID3D11DeviceContext _context = null!;
    private IDXGIOutputDuplication _duplication = null!;
    private IDXGIOutput? _output;
    private ID3D11Texture2D? _staging;
    private int _srcW;
    private int _srcH;
    private readonly int _dstW;
    private readonly int _dstH;
    private byte[]? _dst;
    private readonly D3dEncodeDevice? _shared;
    private bool _ownsDevice = true;
    private GpuFrame? _gpu;
    // The shared device's lock when capturing on it; own device: nothing else uses the context.
    private readonly object _ctxLock;
    private Thread? _thread;
    private bool _stopThread;
    private readonly object _timingSync = new();
    private double _copyMsSum;
    private int _copyFrames;
    private int _busyPolls;
    // Regions of the GPU picture not yet copied into the CPU buffer (lazy readback); under _ctxLock.
    private readonly List<Rectangle> _cpuPending = new();
    private bool _cpuPendingAll = true;
    private int[] _xMap = Array.Empty<int>();
    private int[] _yMap = Array.Empty<int>();
    private bool _identity;

    // Dirty regions (dst pixels) accumulated since the last emitted frame — includes frames that
    // were only pumped (drained) so nothing is lost between real captures.
    private readonly List<Rectangle> _pending = new();
    private bool _pendingAll = true; // first frame is whole
    private RawRect[] _dirtyBuf = new RawRect[64];
    private OutduplMoveRect[] _moveBuf = new OutduplMoveRect[16];

    // Step-0 instrumentation: GPU copy + map wait, and CPU region copy/scale (ms per emitted frame).
    private double _readbackMsSum;
    private double _scaleMsSum;
    private int _timedFrames;

    /// <summary>Average readback/scale ms per captured frame since last call; resets counters.</summary>
    public (double ReadbackMs, double ScaleMs) TakeTimings()
    {
        var n = Math.Max(1, _timedFrames);
        var r = (_readbackMsSum / n, _scaleMsSum / n);
        _readbackMsSum = 0;
        _scaleMsSum = 0;
        _timedFrames = 0;
        return r;
    }

    public int MonitorLeft { get; private set; }
    public int MonitorTop { get; private set; }
    public int MonitorWidth => _srcW;
    public int MonitorHeight => _srcH;

    /// <summary>One DXGI output (monitor) on one adapter.</summary>
    public sealed record OutputInfo(
        int AdapterIndex, string Adapter, int OutputIndex, string DeviceName,
        int Left, int Top, int Width, int Height, bool Attached)
    {
        public bool IsPrimaryPosition => Left == 0 && Top == 0;
        public override string ToString() =>
            $"adapter {AdapterIndex} '{Adapter}' output {OutputIndex} {DeviceName} {Width}x{Height} at {Left},{Top}" +
            (Attached ? "" : " (not attached)");
    }

    /// <summary>All outputs of all adapters, in DXGI order.</summary>
    public static IReadOnlyList<OutputInfo> ListOutputs()
    {
        var list = new List<OutputInfo>();
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        for (uint a = 0; factory.EnumAdapters1(a, out var adapter).Success; a++)
        {
            using (adapter)
            {
                var name = adapter.Description1.Description ?? $"Adapter{a}";
                for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
                {
                    using (output)
                    {
                        var d = output.Description;
                        var r = d.DesktopCoordinates;
                        list.Add(new OutputInfo((int)a, name, (int)o, d.DeviceName ?? "?",
                            r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, d.AttachedToDesktop));
                    }
                }
            }
        }
        return list;
    }

    /// <summary>
    /// Which monitor to capture, from <c>AFTERSCREEN_OUTPUT</c> (or <paramref name="spec"/>):
    /// unset / "primary" = the monitor at the desktop origin (mirror, as before);
    /// "WxH" (e.g. 2560x1440) = an attached output of that size, a non-primary one first
    /// (the virtual extended display); a number = index in <see cref="ListOutputs"/>.
    /// </summary>
    public static OutputInfo? SelectOutput(IReadOnlyList<OutputInfo> outputs, string? spec = null)
    {
        spec ??= Environment.GetEnvironmentVariable("AFTERSCREEN_OUTPUT");
        var attached = outputs.Where(o => o.Attached).ToList();
        if (attached.Count == 0)
            attached = outputs.ToList();
        if (string.IsNullOrWhiteSpace(spec) || spec.Equals("primary", StringComparison.OrdinalIgnoreCase))
            return attached.FirstOrDefault(o => o.IsPrimaryPosition) ?? attached.FirstOrDefault();
        if (int.TryParse(spec, out var index))
            return index >= 0 && index < outputs.Count ? outputs[index] : null;
        var m = System.Text.RegularExpressions.Regex.Match(spec, @"^(\d+)x(\d+)$");
        if (m.Success)
        {
            int w = int.Parse(m.Groups[1].Value), h = int.Parse(m.Groups[2].Value);
            var sized = attached.Where(o => o.Width == w && o.Height == h).ToList();
            return sized.FirstOrDefault(o => !o.IsPrimaryPosition) ?? sized.FirstOrDefault();
        }
        return null;
    }

    /// <summary>
    /// Desktop size of the output <see cref="Start"/> will duplicate, or null.
    /// Lets the stream size follow the monitor so mirror text is copied 1:1, not resampled.
    /// </summary>
    public static (int Width, int Height)? QueryPrimarySize()
    {
        try
        {
            var o = SelectOutput(ListOutputs());
            return o is null || o.Width <= 0 || o.Height <= 0 ? null : (o.Width, o.Height);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// <paramref name="shared"/>: a D3D device to capture on. When it sits on the monitor's adapter and the
    /// stream is the monitor's size, the picture is kept in a GPU texture (<see cref="HasGpuFrame"/>) that the
    /// GPU tile encoder reads in place; otherwise capture falls back to the CPU buffer.
    /// </summary>
    public DxgiCapture(int destWidth = 2880, int destHeight = 1620, D3dEncodeDevice? shared = null)
    {
        _dstW = destWidth;
        _dstH = destHeight;
        _shared = shared;
        _ctxLock = shared?.ContextLock ?? new object();
    }

    public bool HasGpuFrame => _gpu is not null;

    /// <summary>The persistent GPU picture (always the latest capture); null on the CPU path.</summary>
    public GpuFrame? Gpu => _gpu;

    /// <summary>The output that was selected for this capture (set by <see cref="Start"/>).</summary>
    public OutputInfo? Selected { get; private set; }

    public void Start()
    {
        var sel = SelectOutput(ListOutputs())
                  ?? throw new InvalidOperationException(
                      $"no monitor matches AFTERSCREEN_OUTPUT='{Environment.GetEnvironmentVariable("AFTERSCREEN_OUTPUT")}'");
        Selected = sel;

        // The device must live on the adapter that owns the output (a virtual display can sit on
        // a different adapter than the primary monitor).
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        factory.EnumAdapters1((uint)sel.AdapterIndex, out var adapter).CheckError();
        using (adapter)
        {
            var luid = ((long)adapter.Description1.Luid.HighPart << 32) | (uint)adapter.Description1.Luid.LowPart;
            var useShared = _shared is not null && sel.Width == _dstW && sel.Height == _dstH
                && _shared.Adapter.AdapterLuid == luid
                && !string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_GPU"), "0", StringComparison.Ordinal);
            if (useShared)
            {
                _device = _shared!.Device;
                _context = _shared.Context;
                _ownsDevice = false;
            }
            else
            {
                D3D11.D3D11CreateDevice(
                    adapter,
                    DriverType.Unknown,
                    DeviceCreationFlags.BgraSupport,
                    new[] { FeatureLevel.Level_11_0 },
                    out _device,
                    out _,
                    out _context).CheckError();
            }

            adapter.EnumOutputs((uint)sel.OutputIndex, out var output).CheckError();
            using var output1 = output.QueryInterface<IDXGIOutput1>();
            _duplication = output1.DuplicateOutput(_device);
            _output = output;
        }
        var desc = _output!.Description;
        MonitorLeft = desc.DesktopCoordinates.Left;
        MonitorTop = desc.DesktopCoordinates.Top;
        _srcW = desc.DesktopCoordinates.Right - desc.DesktopCoordinates.Left;
        _srcH = desc.DesktopCoordinates.Bottom - desc.DesktopCoordinates.Top;
        // GPU picture when the device is shared and the monitor is the stream size (no resampling needed).
        if (!_ownsDevice && _srcW == _dstW && _srcH == _dstH)
            _gpu = new GpuFrame(_device, _srcW, _srcH);
        else
            _dst = new byte[_dstW * _dstH * 4];

        _identity = _srcW == _dstW && _srcH == _dstH;
        _xMap = new int[_dstW];
        _yMap = new int[_dstH];
        for (var x = 0; x < _dstW; x++) _xMap[x] = (int)((long)x * _srcW / _dstW);
        for (var y = 0; y < _dstH; y++) _yMap[y] = (int)((long)y * _srcH / _dstH);
    }

    /// <summary>Acquire+release only — keeps duplication alive without CPU readback.</summary>
    public bool TryPump(int timeoutMs = 16)
    {
        var result = _duplication.AcquireNextFrame((uint)timeoutMs, out var frameInfo, out var resource);
        if (result.Failure)
            return false;
        try
        {
            AccumulateDirty(frameInfo);
        }
        finally
        {
            resource.Dispose();
            _duplication.ReleaseFrame();
        }
        return true;
    }

    public bool TryCapture(out CapturedFrame? frame, int timeoutMs = 16)
    {
        frame = null;
        var result = _duplication.AcquireNextFrame((uint)timeoutMs, out var frameInfo, out var resource);
        if (result.Failure)
            return false;

        try
        {
            AccumulateDirty(frameInfo);
            // Pointer-only update: desktop pixels are unchanged, nothing to emit.
            if (!_pendingAll && _pending.Count == 0)
                return false;

            if (_gpu is not null)
            {
                frame = CopyToGpu(resource, frameInfo);
                return true;
            }

            using var tex = resource.QueryInterface<ID3D11Texture2D>();
            EnsureStaging(_srcW, _srcH);
            var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
            _context.CopyResource(_staging!, tex);
            var mapped = _context.Map(_staging!, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            var t1 = System.Diagnostics.Stopwatch.GetTimestamp();
            try
            {
                var rowPitch = (int)mapped.RowPitch;
                IReadOnlyList<Rectangle>? dirty;
                if (_pendingAll)
                {
                    CopyRegion(mapped.DataPointer, rowPitch, new Rectangle(0, 0, _dstW, _dstH));
                    dirty = null;
                }
                else
                {
                    foreach (var r in _pending)
                        CopyRegion(mapped.DataPointer, rowPitch, r);
                    dirty = _pending.ToArray();
                }
                _pending.Clear();
                _pendingAll = false;

                var t2 = System.Diagnostics.Stopwatch.GetTimestamp();
                _readbackMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(t0, t1).TotalMilliseconds;
                _scaleMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(t1, t2).TotalMilliseconds;
                _timedFrames++;

                frame = new CapturedFrame
                {
                    Width = _dstW,
                    Height = _dstH,
                    Bgra = _dst!,
                    TimestampQpc = frameInfo.LastPresentTime,
                    Dirty = dirty,
                };
                return true;
            }
            finally
            {
                _context.Unmap(_staging!, 0);
            }
        }
        finally
        {
            resource.Dispose();
            _duplication.ReleaseFrame();
        }
    }

    /// <summary>
    /// GPU path: updates the persistent texture for the pending regions only (GPU to GPU, no readback), under the
    /// context lock so no encode sequence sees a half-applied update.
    /// </summary>
    private CapturedFrame CopyToGpu(IDXGIResource resource, in OutduplFrameInfo frameInfo)
    {
        using var gpuSrc = resource.QueryInterface<ID3D11Texture2D>();
        IReadOnlyList<Rectangle>? gpuDirty;
        var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        lock (_ctxLock)
        {
            if (_pendingAll)
            {
                _context.CopyResource(_gpu!.Texture, gpuSrc);
                gpuDirty = null;
                _cpuPending.Clear();
                _cpuPendingAll = true;
            }
            else
            {
                foreach (var r in _pending)
                    _context.CopySubresourceRegion(_gpu!.Texture, 0, (uint)r.Left, (uint)r.Top, 0, gpuSrc, 0,
                        new Vortice.Mathematics.Box(r.Left, r.Top, 0, r.Right, r.Bottom, 1));
                gpuDirty = _pending.ToArray();
                if (!_cpuPendingAll)
                {
                    _cpuPending.AddRange(gpuDirty);
                    if (_cpuPending.Count > CapturedFrame.MaxRegions)
                    {
                        _cpuPending.Clear();
                        _cpuPendingAll = true;
                    }
                }
            }
        }
        lock (_timingSync)
        {
            _copyMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalMilliseconds;
            _copyFrames++;
        }
        _pending.Clear();
        _pendingAll = false;
        return new CapturedFrame
        {
            Width = _dstW,
            Height = _dstH,
            TimestampQpc = frameInfo.LastPresentTime,
            Dirty = gpuDirty,
            Gpu = _gpu,
            CpuProvider = SyncCpu,
        };
    }

    /// <summary>
    /// Mac <c>Capture</c> (SCStream on its own queue): a dedicated thread owns the duplication and hands each frame
    /// with new desktop content to <paramref name="onFrame"/>, so capture keeps running while a frame encodes.
    /// GPU path only; <see cref="TryCapture"/> / <see cref="TryPump"/> must not be used while it runs.
    /// </summary>
    public void StartThread(Action<CapturedFrame> onFrame)
    {
        if (_gpu is null)
            throw new InvalidOperationException("capture thread needs the GPU picture");
        if (_thread is not null)
            return;
        _stopThread = false;
        _thread = new Thread(() => CaptureLoop(onFrame))
        {
            IsBackground = true,
            Name = "afterscreen.capture",
            Priority = ThreadPriority.AboveNormal,
        };
        _thread.Start();
    }

    public void StopThread()
    {
        var t = _thread;
        if (t is null)
            return;
        Volatile.Write(ref _stopThread, true);
        t.Join(2000);
        _thread = null;
    }

    private const int DxgiWaitTimeout = unchecked((int)0x887A0027);

    /// <summary>
    /// Polls with a zero timeout: on a multithread-protected device a waiting AcquireNextFrame holds the device
    /// lock, which stalled the encode thread's context calls for tens of milliseconds. Polls only while the
    /// context lock is free, so a poll never lands between the calls of a tile encode or video conversion; the
    /// desktop changes meanwhile are kept by the duplication and arrive with the next acquired frame.
    /// </summary>
    private void CaptureLoop(Action<CapturedFrame> onFrame)
    {
        using var timer = Session.HighResTimer.Begin();
        var reported = false;
        while (!Volatile.Read(ref _stopThread))
        {
            if (!Monitor.TryEnter(_ctxLock))
            {
                Interlocked.Increment(ref _busyPolls);
                timer.Sleep(1);
                continue;
            }
            CapturedFrame? frame = null;
            var sleepMs = 0;
            try
            {
                var result = _duplication.AcquireNextFrame(0, out var frameInfo, out var resource);
                if (result.Failure)
                {
                    sleepMs = result.Code == DxgiWaitTimeout ? 1 : 50;
                }
                else
                {
                    try
                    {
                        AccumulateDirty(frameInfo);
                        // Pointer-only update: desktop pixels are unchanged, nothing to emit.
                        if (_pendingAll || _pending.Count > 0)
                            frame = CopyToGpu(resource, frameInfo);
                    }
                    finally
                    {
                        resource.Dispose();
                        _duplication.ReleaseFrame();
                    }
                }
            }
            catch (Exception ex)
            {
                if (!reported) Console.Error.WriteLine($"[capture] {ex.GetType().Name}: {ex.Message}");
                reported = true;
                sleepMs = 50;
            }
            finally
            {
                Monitor.Exit(_ctxLock);
            }
            if (sleepMs > 0)
            {
                timer.Sleep(sleepMs);
                continue;
            }
            if (frame is null)
                continue;
            try { onFrame(frame); }
            catch (ObjectDisposedException) { return; }
        }
    }

    /// <summary>
    /// Capture thread: average ms issuing a frame's region copies, frames copied, and polls skipped because an
    /// encode held the context; resets.
    /// </summary>
    public (double CopyMs, int Frames, int BusyPolls) TakeCopyTimings()
    {
        lock (_timingSync)
        {
            var r = (_copyMsSum / Math.Max(1, _copyFrames), _copyFrames, Interlocked.Exchange(ref _busyPolls, 0));
            _copyMsSum = 0;
            _copyFrames = 0;
            return r;
        }
    }

    /// <summary>Fold this acquired frame's dirty + move destination rects into the pending set.</summary>
    private void AccumulateDirty(in OutduplFrameInfo info)
    {
        if (_pendingAll)
            return;
        // No desktop update (cursor only): pixels unchanged.
        if (info.LastPresentTime == 0)
            return;
        if (info.TotalMetadataBufferSize == 0)
        {
            _pendingAll = true;
            return;
        }

        try
        {
            var rectSize = Marshal.SizeOf<RawRect>();
            var moveSize = Marshal.SizeOf<OutduplMoveRect>();

            var res = _duplication.GetFrameMoveRects((uint)(_moveBuf.Length * moveSize), _moveBuf, out var moveBytes);
            if (res.Failure && moveBytes > _moveBuf.Length * moveSize)
            {
                _moveBuf = new OutduplMoveRect[(int)(moveBytes / moveSize) + 4];
                res = _duplication.GetFrameMoveRects((uint)(_moveBuf.Length * moveSize), _moveBuf, out moveBytes);
            }
            if (res.Failure) { MarkAll(); return; }
            for (var i = 0; i < (int)(moveBytes / moveSize); i++)
            {
                var d = _moveBuf[i].DestinationRect;
                AddSrcRect(d.Left, d.Top, d.Right, d.Bottom);
            }

            res = _duplication.GetFrameDirtyRects((uint)(_dirtyBuf.Length * rectSize), _dirtyBuf, out var dirtyBytes);
            if (res.Failure && dirtyBytes > _dirtyBuf.Length * rectSize)
            {
                _dirtyBuf = new RawRect[(int)(dirtyBytes / rectSize) + 8];
                res = _duplication.GetFrameDirtyRects((uint)(_dirtyBuf.Length * rectSize), _dirtyBuf, out dirtyBytes);
            }
            if (res.Failure) { MarkAll(); return; }
            for (var i = 0; i < (int)(dirtyBytes / rectSize); i++)
            {
                var r = _dirtyBuf[i];
                AddSrcRect(r.Left, r.Top, r.Right, r.Bottom);
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[capture] dirty rects unavailable ({ex.GetType().Name}: {ex.Message}); whole frames");
            MarkAll();
        }
    }

    private void MarkAll()
    {
        _pendingAll = true;
        _pending.Clear();
    }

    /// <summary>Source-pixel rect (right/bottom exclusive) → padded dst-pixel rect.</summary>
    private void AddSrcRect(int l, int t, int r, int b)
    {
        if (_pendingAll)
            return;
        var dl = Math.Max(0, (int)((long)l * _dstW / _srcW) - 1);
        var dt = Math.Max(0, (int)((long)t * _dstH / _srcH) - 1);
        var dr = Math.Min(_dstW, (int)(((long)r * _dstW + _srcW - 1) / _srcW) + 1);
        var db = Math.Min(_dstH, (int)(((long)b * _dstH + _srcH - 1) / _srcH) + 1);
        if (dr <= dl || db <= dt)
            return;
        if (_pending.Count >= CapturedFrame.MaxRegions)
        {
            MarkAll();
            return;
        }
        _pending.Add(new Rectangle(dl, dt, dr - dl, db - dt));
    }

    /// <summary>Copy (and nearest-scale) one dst-pixel region out of the mapped staging texture.</summary>
    private unsafe void CopyRegion(IntPtr mappedBase, int rowPitch, Rectangle d)
    {
        var dst = _dst!;
        fixed (byte* pDst = dst)
        {
            for (var y = d.Top; y < d.Bottom; y++)
            {
                var srow = (byte*)mappedBase + (long)_yMap[y] * rowPitch;
                var drow = pDst + ((long)y * _dstW + d.Left) * 4;
                if (_identity)
                {
                    Buffer.MemoryCopy(srow + (long)d.Left * 4, drow, (long)d.Width * 4, (long)d.Width * 4);
                }
                else
                {
                    var s32 = (uint*)srow;
                    var d32 = (uint*)drow;
                    for (var x = 0; x < d.Width; x++)
                        d32[x] = s32[_xMap[d.Left + x]];
                }
            }
        }
    }

    private void EnsureStaging(int w, int h)
    {
        if (_staging is not null)
            return;
        _staging = _device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
            BindFlags = BindFlags.None,
        });
    }

    /// <summary>
    /// Copies the regions changed since the last call from the GPU picture into the CPU buffer and returns it.
    /// Nothing is copied when nothing changed, and nothing at all unless a consumer asks for system memory.
    /// </summary>
    private byte[] SyncCpu()
    {
        lock (_ctxLock)
            return SyncCpuLocked();
    }

    private byte[] SyncCpuLocked()
    {
        _dst ??= new byte[_dstW * _dstH * 4];
        if (!_cpuPendingAll && _cpuPending.Count == 0)
            return _dst;
        var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        EnsureStaging(_srcW, _srcH);
        _context.CopyResource(_staging!, _gpu!.Texture);
        var mapped = _context.Map(_staging!, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        var t1 = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            var rowPitch = (int)mapped.RowPitch;
            if (_cpuPendingAll)
                CopyRegion(mapped.DataPointer, rowPitch, new Rectangle(0, 0, _dstW, _dstH));
            else
                foreach (var r in _cpuPending)
                    CopyRegion(mapped.DataPointer, rowPitch, r);
        }
        finally
        {
            _context.Unmap(_staging!, 0);
        }
        _cpuPending.Clear();
        _cpuPendingAll = false;
        var t2 = System.Diagnostics.Stopwatch.GetTimestamp();
        _readbackMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(t0, t1).TotalMilliseconds;
        _scaleMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(t1, t2).TotalMilliseconds;
        _timedFrames++;
        return _dst;
    }

    public void Dispose()
    {
        StopThread();
        _gpu?.Dispose();
        _staging?.Dispose();
        _duplication?.Dispose();
        _output?.Dispose();
        if (_ownsDevice)
        {
            _context?.Dispose();
            _device?.Dispose();
        }
    }
}
