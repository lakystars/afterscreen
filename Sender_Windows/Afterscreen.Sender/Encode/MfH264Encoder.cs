using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Afterscreen.Protocol;
using SharpGen.Runtime;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;
using MapFlags = Vortice.Direct3D11.MapFlags;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// Media Foundation H.264 encoder.
/// Prefers hardware MFTs (Iris QSV / NVIDIA / AMD) with DXGI device manager; falls back to software sync.
/// </summary>
public sealed class MfH264Encoder : IVideoEncoder
{
    private const int MfEventFlagNoWait = 1;

    private static int _mfRefs;

    private readonly VideoCodec _codec;
    private readonly bool _tenBit;
    private readonly IMFTransform _transform;
    private readonly IMFDXGIDeviceManager? _dxgiManager;
    private readonly D3dEncodeDevice? _d3d;
    private readonly IMFMediaEventGenerator? _events;
    private readonly bool _async;
    private readonly int _width;
    private readonly int _height;
    private readonly int _outputBufferSize;
    private readonly bool _providesSamples;
    private readonly long _frameDuration;
    private readonly byte[] _nv12;
    private byte[]? _scaleScratch; // reuse — avoid 8MB alloc per frame under scroll load
    private ID3D11Texture2D? _nv12Gpu;
    private ID3D11Texture2D? _nv12Staging;
    // One recycled system-memory sample — CreateNv12Sample-per-frame leaked native WS to multi-GB.
    private IMFSample? _inputSample;
    private IMFMediaBuffer? _inputBuffer;
    private long _pts;
    private byte[][]? _parameterSets;
    private bool _disposed;
    // Async MFTs must wait for METransformNeedInput before ProcessInput.
    private bool _awaitingInput;
    // True after ProcessInput until we DrainOne — prevents stuffing QSV with samples (WS→GB).
    private bool _inputInFlight;
    private long _inFlightSinceMs;
    private bool _proving;

    public string BackendName { get; }
    public bool IsHardware { get; }
    public bool InputInFlight => _inputInFlight;

    /// <summary>
    /// Mac EncoderCapacity.measure: frames per second this encoder sustains with every frame changed in full (video-like
    /// colour waves with light grain, three phases), back to back as fast as accepted, after a short warm-up. The
    /// YUV frame is prepared up front so the number is the encoder's, not the conversion's. 0 when it cannot start.
    /// </summary>
    internal double Benchmark(int frames, int warmup)
    {
        var phases = new byte[3][];
        for (var i = 0; i < 3; i++)
        {
            phases[i] = new byte[_nv12.Length];
            FillBenchmarkFrame(phases[i], i);
        }
        var outputs = 0;
        var started = 0L;
        var submitted = 0;
        var deadline = Environment.TickCount64 + 15_000;
        _proving = false;
        while (outputs < warmup + frames && Environment.TickCount64 < deadline)
        {
            EncodedVideoFrame? f;
            if (_inputInFlight)
                f = PollOutput(20);
            else
            {
                Buffer.BlockCopy(phases[submitted % 3], 0, _nv12, 0, _nv12.Length);
                f = EncodeCore(null, _width, _height, null, null, forceKeyframe: submitted == 0, skipConvert: true);
                submitted++;
            }
            if (f is null) continue;
            outputs++;
            if (outputs == warmup) started = System.Diagnostics.Stopwatch.GetTimestamp();
        }
        if (outputs < warmup + frames || started == 0) return 0;
        return frames / System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalSeconds;
    }

    private void FillBenchmarkFrame(byte[] buf, int phase)
    {
        var w = _width; var h = _height;
        var wave = new int[256];
        for (var i = 0; i < 256; i++) wave[i] = (int)(100 + 100 * Math.Sin(i * Math.PI / 128));
        uint x32 = (uint)(phase + 1) * 2654435761u;
        var bytesPer = _tenBit ? 2 : 1;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                x32 ^= x32 << 13; x32 ^= x32 >> 17; x32 ^= x32 << 5;
                var luma = Math.Clamp(wave[(x / 4 + phase * 9) & 255] / 2 + wave[(y / 3 + phase * 7) & 255] / 2 + (int)(x32 & 15), 16, 235);
                var o = (y * w + x) * bytesPer;
                if (_tenBit) { var v = (ushort)(((luma << 2)) << 6); buf[o] = (byte)v; buf[o + 1] = (byte)(v >> 8); }
                else buf[o] = (byte)luma;
            }
        var uvStart = w * h * bytesPer;
        for (var y = 0; y < h / 2; y++)
            for (var x = 0; x < w; x += 2)
            {
                var cb = Math.Clamp(wave[((x + y) / 5 + phase * 5) & 255] + 28, 16, 240);
                var cr = Math.Clamp(wave[(x / 4 + y / 3 + phase * 3) & 255] + 28, 16, 240);
                var o = uvStart + (y * w + x) * bytesPer;
                if (_tenBit)
                {
                    var u = (ushort)((cb << 2) << 6); var v = (ushort)((cr << 2) << 6);
                    buf[o] = (byte)u; buf[o + 1] = (byte)(u >> 8); buf[o + 2] = (byte)v; buf[o + 3] = (byte)(v >> 8);
                }
                else { buf[o] = (byte)cb; buf[o + 1] = (byte)cr; }
            }
    }

    public bool SetBitrate(int bitsPerSecond)
    {
        if (!IsHardware) return false;
        var api = CodecApi.SetBitrate(_transform, bitsPerSecond);
        var type = false;
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_BITRATE_TYPE") == "1")
        {
            try
            {
                using var t = _transform.GetOutputCurrentType(0);
                t.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitsPerSecond);
                _transform.SetOutputType(0, t, 0);
                type = true;
            }
            catch (Exception ex) { Console.WriteLine($"  SetBitrate type failed: {ex.Message}"); }
        }
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_BITRATE_FLUSH") == "1") DebugRestart(1);
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE") == "1") Console.WriteLine($"[mf] SetBitrate {bitsPerSecond / 1000} kbps api={api} type={type}");
        return api || type;
    }

    public bool SetQuality(int quality0To100)
    {
        if (!IsHardware) return false;
        return CodecApi.SetQuality(_transform, (uint)Math.Clamp(quality0To100, 0, 100));
    }

    /// <summary>0 polls once without waiting.</summary>
    public EncodedVideoFrame? PollOutput(int budgetMs)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_stashed is { } stashed)
        {
            _stashed = null;
            return stashed;
        }
        if (!_inputInFlight)
            return null;
        var drained = _async ? DrainPending(budgetMs) : DrainOne();
        if (drained is null)
        {
            if (Environment.TickCount64 - _inFlightSinceMs > 500)
            {
                _inputInFlight = false;
                _awaitingInput = true;
            }
            return null;
        }
        _inputInFlight = false;
        _awaitingInput = true;
        NoteLatency();
        return FinishFrame(drained);
    }

    // Output found while submitting without waiting (an input the stall guard gave up on); PollOutput returns it.
    private EncodedVideoFrame? _stashed;
    private long _submittedTs;
    private double _tLatencyMs;
    private int _tLatencyN;

    private void NoteLatency()
    {
        if (_submittedTs == 0) return;
        _tLatencyMs += System.Diagnostics.Stopwatch.GetElapsedTime(_submittedTs).TotalMilliseconds;
        _tLatencyN++;
        _submittedTs = 0;
    }

    /// <summary>Average ms from ProcessInput to its output collected by <see cref="PollOutput"/>; resets.</summary>
    public double TakeOutputLatency()
    {
        var r = _tLatencyN > 0 ? _tLatencyMs / _tLatencyN : 0;
        _tLatencyMs = 0;
        _tLatencyN = 0;
        return r;
    }

    /// <summary>
    /// An async MFT: <see cref="SubmitPrepared"/> can hand it a frame without waiting for the output, so the stream
    /// loop prepares the next frame while this one encodes (Mac: VideoEncoder completes by callback).
    /// </summary>
    public bool CanSubmitWithoutWait => _async && _events is not null && CanEncodeGpu;

    /// <summary>An input in flight or an output waiting for <see cref="PollOutput"/>.</summary>
    public bool HasOutputPending => _inputInFlight || _stashed is not null;

    // Two recycled input samples: the next frame is written into one while the encoder reads the other (QSV asks for
    // the next input only after the previous output, so never more than one in flight).
    private readonly IMFSample?[] _ring = new IMFSample?[2];
    private readonly IMFMediaBuffer?[] _ringBuffers = new IMFMediaBuffer?[2];
    private int _ringSubmitted = 1;
    private int _ringPrepared = -1;

    /// <summary>
    /// GPU scale + YUV convert of the picture straight into the input sample <see cref="SubmitPrepared"/> hands over
    /// next. Leaves the in-flight input alone, so it runs while the previous frame encodes.
    /// </summary>
    public void ConvertGpu(D3dEncodeDevice device, Capture.GpuFrame frame)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_gpuConv is null && !_gpuConvFailed)
        {
            try { _gpuConv = new GpuVideoConverter(device, _width, _height, _tenBit); }
            catch (Exception ex) { _gpuConvFailed = true; Console.WriteLine("  GPU video convert unavailable: " + ex.Message); }
        }
        if (_gpuConv is null)
            throw new InvalidOperationException("GPU video converter unavailable");
        var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        var slot = _ringSubmitted ^ 1;
        _ringPrepared = -1;
        if (_ring[slot] is null)
        {
            _ringBuffers[slot] = MediaFactory.MFCreateMemoryBuffer(_nv12.Length);
            _ring[slot] = MediaFactory.MFCreateSample();
            _ring[slot]!.AddBuffer(_ringBuffers[slot]);
        }
        var buffer = _ringBuffers[slot]!;
        buffer.Lock(out var ptr, out _, out _);
        try { _gpuConv.Convert(frame, ptr); }
        finally { buffer.Unlock(); }
        buffer.CurrentLength = _nv12.Length;
        _ringPrepared = slot;
        _tNv12Ms += System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalMilliseconds;
    }

    /// <summary>A frame from <see cref="ConvertGpu"/> waits for <see cref="SubmitPrepared"/>.</summary>
    public bool HasPrepared => _ringPrepared >= 0;

    /// <summary>
    /// Hands the frame from <see cref="ConvertGpu"/> to the encoder without waiting for its output
    /// (<see cref="PollOutput"/> collects it). False while an input is in flight, with nothing prepared, or when the
    /// encoder did not take it (the prepared frame is dropped then).
    /// </summary>
    public bool SubmitPrepared(bool forceKeyframe)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_inputInFlight || _ringPrepared < 0)
            return false;
        var tC = System.Diagnostics.Stopwatch.GetTimestamp();
        var slot = _ringPrepared;
        _ringPrepared = -1;
        _ringSubmitted = slot;
        var sample = _ring[slot]!;
        sample.SampleTime = _pts;
        sample.SampleDuration = _frameDuration;
        var tD = System.Diagnostics.Stopwatch.GetTimestamp();
        if (forceKeyframe)
        {
            try { sample.Set(SampleAttributeKeys.CleanPoint, true); } catch { /* optional */ }
            if (IsHardware)
                CodecApi.RequestKeyframe(_transform);
        }
        var stashed = EncodeAsync(sample, out var accepted, waitForOutput: false);
        if (stashed is not null)
            _stashed = FinishFrame(stashed);
        _tSampleMs += System.Diagnostics.Stopwatch.GetElapsedTime(tC, tD).TotalMilliseconds;
        _tSubmitMs += System.Diagnostics.Stopwatch.GetElapsedTime(tD).TotalMilliseconds;
        _tFrames++;
        _pts += _frameDuration;
        return accepted;
    }

    private MfH264Encoder(
        IMFTransform transform,
        IMFDXGIDeviceManager? dxgiManager,
        D3dEncodeDevice? d3d,
        string name,
        int width,
        int height,
        double fps,
        bool async,
        bool hardware,
        VideoCodec codec,
        bool tenBit)
    {
        _codec = codec;
        _tenBit = tenBit;
        _transform = transform;
        _dxgiManager = dxgiManager;
        _d3d = d3d;
        _async = async;
        IsHardware = hardware;
        BackendName = name;
        _width = width;
        _height = height;
        _frameDuration = (long)(10_000_000.0 / Math.Max(1.0, fps));
        // NV12: 1.5 bytes per pixel; P010 (10-bit): 3 bytes per pixel.
        _nv12 = new byte[tenBit ? width * height * 3 : width * height + width * height / 2];
        var osi = transform.GetOutputStreamInfo(0);
        _outputBufferSize = Math.Max(osi.Size, Math.Max(256 * 1024, width * height));
        _providesSamples = ((OutputStreamInfoFlags)osi.Flags & OutputStreamInfoFlags.OutputStreamProvidesSamples) != 0
                           || ((OutputStreamInfoFlags)osi.Flags & OutputStreamInfoFlags.OutputStreamCanProvideSamples) != 0;
        if (async)
        {
            try { _events = transform.QueryInterface<IMFMediaEventGenerator>(); }
            catch (Exception ex)
            {
                _events = null;
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                    Console.Error.WriteLine($"[mf] IMFMediaEventGenerator QI failed: {ex.Message}");
            }
            if (_events is null && string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                Console.Error.WriteLine("[mf] WARNING: async MFT without event generator — encode will stall");
        }
    }

    public static MfH264Encoder? TryCreate(
        VideoLayer layer, double fps, GpuAdapterInfo? adapter, D3dEncodeDevice? d3d = null)
    {
        if (layer.Codec is not (VideoCodec.h264 or VideoCodec.hevc))
            return null;
        var codec = layer.Codec;
        var tenBit = layer.TenBit && codec == VideoCodec.hevc; // Main10 exists for HEVC only

        EnsureStartup();
        var w = layer.Pixels.Width;
        var h = layer.Pixels.Height;
        var bitrate = Math.Max(1_000_000, layer.Bitrate);

        IMFDXGIDeviceManager? sharedMgr = null;
        if (d3d is not null)
        {
            try
            {
                // Vortice 3.8: MFCreateDXGIDeviceManager() + ResetDevice(device); token via ResetToken.
                sharedMgr = MediaFactory.MFCreateDXGIDeviceManager();
                sharedMgr.ResetDevice(d3d.Device).CheckError();
            }
            catch
            {
                sharedMgr?.Dispose();
                sharedMgr = null;
            }
        }

        // Prefer HW that actually proves output. Iris QSV often accepts DXGI ProcessInput
        // but never emits METransformHaveOutput; system-memory NV12 into QSV is the
        // known-good path (Intel/community). DXGI is tried after that.
        var attempts = new (EnumFlag flags, bool hwOnly, bool useDxgi)[]
        {
            (EnumFlag.EnumFlagAsyncmft | EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter, true, false),
            (EnumFlag.EnumFlagSyncmft | EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter, true, false),
            (EnumFlag.EnumFlagAsyncmft | EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter, true, true),
            (EnumFlag.EnumFlagSyncmft | EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter, true, true),
            (EnumFlag.EnumFlagSyncmft | EnumFlag.EnumFlagSortandfilter, false, false),
        };

        var verbose = string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal);
        void Log(string msg) { if (verbose) Console.Error.WriteLine("[mf] " + msg); }

        foreach (var (flags, hwOnly, useDxgi) in attempts)
        {
            if (useDxgi && sharedMgr is null) continue;
            var mgr = useDxgi ? sharedMgr : null;
            Log($"attempt flags={flags} hwOnly={hwOnly} dxgi={useDxgi}");
            IMFTransform? transform;
            string label;
            bool async;
            try
            {
                transform = ActivateEncoder(flags, w, h, bitrate, fps, mgr, out label, hwOnly, out async, codec, tenBit);
            }
            catch (Exception ex)
            {
                Log($"activate EX {ex.GetType().Name}: {ex.Message}");
                continue;
            }
            if (transform is null) { Log("activate: none"); continue; }

            var hw = label.Contains("Quick Sync", StringComparison.OrdinalIgnoreCase)
                     || label.Contains("Intel", StringComparison.OrdinalIgnoreCase) // Intel Hardware H265 Encoder MFT
                     || label.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase)
                     || label.Contains("AMD", StringComparison.OrdinalIgnoreCase)
                     || label.Contains("DX12", StringComparison.OrdinalIgnoreCase);
            var adapterTag = adapter?.Description ?? "default";
            var mode = async ? "async" : "sync";
            var dxgiTag = useDxgi ? "|dxgi" : "";
            // Ownership of sharedMgr moves to the encoder only when this attempt is kept.
            var enc = new MfH264Encoder(
                transform,
                useDxgi ? sharedMgr : null,
                useDxgi ? d3d : null,
                $"mf-{codec}{(tenBit ? "10" : "")}:{label}|{mode}{dxgiTag}|gpu={adapterTag}",
                w, h, fps, async, hw, codec, tenBit);
            if (useDxgi)
                sharedMgr = null; // encoder owns it now (even if prove fails we dispose enc)

            Log($"proving {enc.BackendName}");
            bool ok;
            try { ok = enc.ProvesOutput(); }
            catch (Exception ex)
            {
                Log($"prove EX {ex.GetType().Name}: {ex.Message}");
                ok = false;
            }
            if (ok)
            {
                Log("prove OK");
                sharedMgr?.Dispose();
                // The prove frames consumed this encoder's first IDR, and QSV ignores
                // ForceKeyFrame/GOP (ICodecAPI is not exposed on the async MFT) — its next IDR
                // comes ~125 frames later, i.e. ~10 s of video-less startup under motion. A
                // second instance that was never fed starts its stream with an IDR + SPS/PPS.
                if (enc.IsHardware && async && !useDxgi)
                {
                    var fresh = TryBuildUnfed(enc, flags, hwOnly, w, h, bitrate, fps, adapterTag, codec, Log);
                    if (fresh is not null)
                        return fresh;
                }
                return enc;
            }

            Log("prove fail");
            enc.Dispose();
            EnsureStartup(); // Dispose released MF ref
            if (useDxgi && d3d is not null && sharedMgr is null)
            {
                // Recreate manager for the next HW attempt.
                try
                {
                    sharedMgr = MediaFactory.MFCreateDXGIDeviceManager();
                    sharedMgr.ResetDevice(d3d.Device).CheckError();
                }
                catch
                {
                    sharedMgr?.Dispose();
                    sharedMgr = null;
                }
            }
        }

        sharedMgr?.Dispose();
        ReleaseStartup();
        return null;
    }

    /// <summary>
    /// Builds a replacement encoder (same settings, never fed a frame) and retires the proven one.
    /// Returns null — leaving <paramref name="proven"/> usable — if the replacement can't be built.
    /// </summary>
    private static MfH264Encoder? TryBuildUnfed(
        MfH264Encoder proven, EnumFlag flags, bool hwOnly, int w, int h, int bitrate, double fps,
        string adapterTag, VideoCodec codec, Action<string> log)
    {
        try
        {
            EnsureStartup(); // the replacement owns one MF reference; proven.Dispose() releases its own
            var transform = ActivateEncoder(flags, w, h, bitrate, fps, null, out var label, hwOnly, out var async, codec, proven._tenBit);
            if (transform is null)
            {
                ReleaseStartup();
                return null;
            }
            var mode = async ? "async" : "sync";
            var fresh = new MfH264Encoder(transform, null, null,
                $"mf-{codec}{(proven._tenBit ? "10" : "")}:{label}|{mode}|gpu={adapterTag}", w, h, fps, async, proven.IsHardware, codec, proven._tenBit);
            fresh._parameterSets = proven._parameterSets;
            proven.Dispose();
            log("replaced proven encoder with an unfed instance (first frame will be an IDR)");
            return fresh;
        }
        catch (Exception ex)
        {
            log($"unfed replacement failed: {ex.GetType().Name}: {ex.Message}");
            ReleaseStartup();
            return null;
        }
    }

    /// <summary>Feed a few synthetic frames; true if the MFT yields at least one AVCC sample.</summary>
    private bool ProvesOutput()
    {
        var verbose = string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal);
        var bgra = new byte[_width * _height * 4];
        Array.Fill(bgra, (byte)32);
        _proving = true;
        try
        {
        // Cap prove time: 45×1.5s HW waits froze BeginStreaming on "Measuring link".
        var limit = IsHardware ? 12 : 8;
        for (var i = 0; i < limit; i++)
        {
            bgra[(i * 17) % bgra.Length] = (byte)(40 + i);
            EncodedVideoFrame? frame;
            try { frame = Encode(bgra, _width, _height, forceKeyframe: i == 0); }
            catch (Exception ex)
            {
                if (verbose && i < 3)
                    Console.Error.WriteLine($"[mf] prove encode[{i}] EX {ex.GetType().Name}: {ex.Message}");
                continue;
            }
            if (frame is not null)
            {
                _parameterSets ??= TryReadSequenceHeader();
                _pts = 0;
                _inputInFlight = false;
                return _parameterSets is { Length: > 0 } || true;
            }
            if (verbose && i < 3)
                Console.Error.WriteLine($"[mf] prove encode[{i}] null");
        }
        _parameterSets ??= TryReadSequenceHeader();
        return false;
        }
        finally
        {
            _proving = false;
            _inputInFlight = false;
        }
    }

    /// <summary>Experiment hook: try different ways of making the next frame an IDR (see idr-probe).</summary>
    internal void DebugRestart(int variant)
    {
        void Msg(TMessageType m) { try { _transform.ProcessMessage(m, UIntPtr.Zero); } catch (Exception ex) { Console.WriteLine($"  msg {m} failed: {ex.Message}"); } }
        void DropEvents()
        {
            if (_events is null) return;
            for (var i = 0; i < 64; i++)
            {
                IMFMediaEvent? ev = null;
                try { ev = _events.GetEvent(MfEventFlagNoWait); } catch { break; }
                ev?.Dispose();
            }
        }
        switch (variant)
        {
            case 1: // flush + restart
                Msg(TMessageType.MessageCommandFlush); DropEvents();
                Msg(TMessageType.MessageNotifyBeginStreaming); Msg(TMessageType.MessageNotifyStartOfStream);
                break;
            case 2: // flush + renegotiate output type
                Msg(TMessageType.MessageCommandFlush); DropEvents();
                try { using var t = _transform.GetOutputCurrentType(0); _transform.SetOutputType(0, t, 0); }
                catch (Exception ex) { Console.WriteLine($"  SetOutputType failed: {ex.Message}"); }
                Msg(TMessageType.MessageNotifyBeginStreaming); Msg(TMessageType.MessageNotifyStartOfStream);
                break;
            case 3: // drain + end-of-stream + start
                Msg(TMessageType.MessageCommandDrain);
                Thread.Sleep(150); DropEvents();
                Msg(TMessageType.MessageNotifyEndOfStream); Msg(TMessageType.MessageNotifyEndStreaming);
                Msg(TMessageType.MessageNotifyBeginStreaming); Msg(TMessageType.MessageNotifyStartOfStream);
                break;
            case 4: // end streaming + begin (no flush)
                Msg(TMessageType.MessageNotifyEndStreaming); DropEvents();
                Msg(TMessageType.MessageNotifyBeginStreaming); Msg(TMessageType.MessageNotifyStartOfStream);
                break;
            case 5: // flush + renegotiate BOTH types
                Msg(TMessageType.MessageCommandFlush); DropEvents();
                try
                {
                    using var o = _transform.GetOutputCurrentType(0); _transform.SetOutputType(0, o, 0);
                    using var i = _transform.GetInputCurrentType(0); _transform.SetInputType(0, i, 0);
                }
                catch (Exception ex) { Console.WriteLine($"  renegotiate failed: {ex.Message}"); }
                Msg(TMessageType.MessageNotifyBeginStreaming); Msg(TMessageType.MessageNotifyStartOfStream);
                break;
        }
        _inputInFlight = false; _awaitingInput = false;
    }

    public EncodedVideoFrame? Encode(byte[] bgra, int srcW, int srcH, bool forceKeyframe)
        => EncodeCore(bgra, srcW, srcH, null, null, forceKeyframe);

    private GpuVideoConverter? _gpuConv;
    private bool _gpuConvFailed;

    /// <summary>
    /// True when <see cref="EncodeGpu"/> can be used for this video size (the converter compiled and the size is
    /// a multiple of 4x2). Falls back to the CPU path otherwise.
    /// </summary>
    public bool CanEncodeGpu => !_gpuConvFailed && GpuVideoConverter.Supports(_width, _height);

    /// <summary>Same as <see cref="Encode"/> but scales and converts on the GPU from the persistent GPU picture.</summary>
    public EncodedVideoFrame? EncodeGpu(D3dEncodeDevice device, Capture.GpuFrame frame, bool forceKeyframe)
    {
        if (_gpuConv is null && !_gpuConvFailed)
        {
            try { _gpuConv = new GpuVideoConverter(device, _width, _height, _tenBit); }
            catch (Exception ex) { _gpuConvFailed = true; Console.WriteLine("  GPU video convert unavailable: " + ex.Message); }
        }
        if (_gpuConv is null)
            throw new InvalidOperationException("GPU video converter unavailable");
        return EncodeCore(null, frame.Width, frame.Height, _gpuConv, frame, forceKeyframe);
    }

    private EncodedVideoFrame? EncodeCore(byte[]? bgra, int srcW, int srcH, GpuVideoConverter? conv, Capture.GpuFrame? gpu, bool forceKeyframe,
        bool skipConvert = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        // Recycled input buffer must not be rewritten while QSV still holds it.
        // Do NOT clear inFlight on a short miss — that abandoned the pending sample,
        // returned nulls in a streak, and kicked hybrid into IDR/BC1 stalls.
        if (_inputInFlight)
        {
            // Live: wait about one frame for HaveOutput. 16ms misses left inFlight set for
            // hundreds of ms → Encode null streak → hybrid fell back to BC1 / IDR storms.
            var drained = _async ? DrainPending(_proving ? 250 : 40) : DrainOne();
            if (drained is not null)
            {
                _inputInFlight = false;
                _awaitingInput = true;
                return FinishFrame(drained);
            }
            // Hard unstick only after a long stall (driver glitch) — not every miss.
            // During prove, clear quickly so the next synthetic frame can submit.
            if (_proving || Environment.TickCount64 - _inFlightSinceMs > 500)
            {
                _inputInFlight = false;
                _awaitingInput = true;
            }
            return null;
        }

        var tA = System.Diagnostics.Stopwatch.GetTimestamp();
        long tB;
        if (skipConvert)
        {
            tB = tA;                              // benchmark: _nv12 already holds the frame
        }
        else if (conv is not null)
        {
            tB = tA;                              // no separate scale stage: one GPU dispatch + readback
            conv.Convert(gpu!, _nv12);
        }
        else
        {
            var scaled = ScaleBgra(bgra!, srcW, srcH, _width, _height, ref _scaleScratch);
            tB = System.Diagnostics.Stopwatch.GetTimestamp();
            if (_tenBit) BgraToP010(scaled, _width, _height, _nv12);
            else BgraToNv12(scaled, _width, _height, _nv12);
        }
        var tC = System.Diagnostics.Stopwatch.GetTimestamp();
        // One recycled IMFSample for the session — per-frame MFCreateMemoryBuffer grew WS to max.
        var sample = CreateNv12Sample(_nv12, _width, _height, _pts, _frameDuration);
        var tD = System.Diagnostics.Stopwatch.GetTimestamp();
        if (!_proving)
        {
            _tScaleMs += System.Diagnostics.Stopwatch.GetElapsedTime(tA, tB).TotalMilliseconds;
            _tNv12Ms += System.Diagnostics.Stopwatch.GetElapsedTime(tB, tC).TotalMilliseconds;
            _tSampleMs += System.Diagnostics.Stopwatch.GetElapsedTime(tC, tD).TotalMilliseconds;
            _tFrames++;
        }
        if (forceKeyframe)
        {
            // Mac VT: ForceKeyFrame only. SW CodecAPI.RequestKeyframe is unsafe — HW-only.
            try { sample.Set(SampleAttributeKeys.CleanPoint, true); } catch { /* optional */ }
            if (IsHardware)
                CodecApi.RequestKeyframe(_transform);
        }

        EncodedVideoFrame? produced = _async
            ? EncodeAsync(sample, out _)
            : EncodeSync(sample, out _);

        if (!_proving)
            _tSubmitMs += System.Diagnostics.Stopwatch.GetElapsedTime(tD).TotalMilliseconds;
        _pts += _frameDuration;
        return produced is null ? null : FinishFrame(produced);
    }

    // Per-stage encode timing (ms per submitted frame since the last TakeStageTimings).
    private double _tScaleMs, _tNv12Ms, _tSampleMs, _tSubmitMs;
    private int _tFrames;

    /// <summary>Average scale / BGRA→NV12 / sample copy / QSV submit+wait ms per frame; resets.</summary>
    public (double Scale, double Nv12, double Sample, double Submit) TakeStageTimings()
    {
        var n = Math.Max(1, _tFrames);
        var r = (_tScaleMs / n, _tNv12Ms / n, _tSampleMs / n, _tSubmitMs / n);
        _tScaleMs = _tNv12Ms = _tSampleMs = _tSubmitMs = 0;
        _tFrames = 0;
        return r;
    }

    private EncodedVideoFrame FinishFrame(EncodedVideoFrame produced)
    {
        _parameterSets ??= produced.ParameterSets ?? TryReadSequenceHeader();

        // Never advertise a keyframe without a real IDR NAL — VT needs type-5 after videoParams.
        if (!produced.Keyframe)
            return produced;

        if (produced.ParameterSets is null && _parameterSets is not null)
        {
            return new EncodedVideoFrame
            {
                Keyframe = true,
                Avcc = produced.Avcc,
                ParameterSets = _parameterSets,
            };
        }

        return produced;
    }

    private EncodedVideoFrame? EncodeSync(IMFSample sample, out bool accepted)
    {
        accepted = false;
        EncodedVideoFrame? produced = null;
        for (var attempt = 0; attempt < 6; attempt++)
        {
            try
            {
                _transform.ProcessInput(0, sample, 0);
                accepted = true;
                _inputInFlight = true;
                _inFlightSinceMs = Environment.TickCount64;
                break;
            }
            catch (SharpGenException)
            {
                var drained = DrainOne();
                if (drained is not null) produced = drained;
                else break;
            }
        }
        produced = DrainOne() ?? produced;
        if (produced is not null)
            _inputInFlight = false;
        return produced;
    }

    /// <summary>
    /// <paramref name="waitForOutput"/> false: returns once the input is taken; an output met on the way (from an
    /// input given up on) is returned and the new input stays in flight.
    /// </summary>
    private EncodedVideoFrame? EncodeAsync(IMFSample sample, out bool accepted, bool waitForOutput = true)
    {
        accepted = false;
        if (_events is null)
            return EncodeSync(sample, out accepted);

        // inFlight handled in Encode() before rewriting the recycled buffer.

        // One frame-time for HaveOutput (Mac VT completes via callback; we must poll).
        // Too short → permanent null/inFlight; too long → capture starves.
        var waitMs = _proving ? (IsHardware ? 400 : 80) : 40;
        var deadline = Environment.TickCount64 + waitMs;
        EncodedVideoFrame? produced = null;
        var submitted = false;
        var verbose = string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal);
        var sawNeed = 0;
        var sawHave = 0;

        while (Environment.TickCount64 <= deadline)
        {
            // Non-blocking poll, then short wait — only ProcessOutput after HaveOutput
            // (ProcessOutput without it → E_UNEXPECTED on QSV provides=True).
            IMFMediaEvent? ev = null;
            try { ev = _events.GetEvent(MfEventFlagNoWait); }
            catch { /* no event yet */ }

            if (ev is null)
            {
                if (!submitted && _awaitingInput)
                {
                    TrySubmit(verbose && sawNeed < 2 ? "ProcessInput" : null);
                    if (submitted && !waitForOutput)
                        break;
                }
                else
                {
                    Thread.Sleep(1);
                }
                continue;
            }

            using (ev)
            {
                var type = (MediaEventTypes)ev.EventType;
                if (type == MediaEventTypes.TransformNeedInput)
                {
                    sawNeed++;
                    _awaitingInput = true;
                    if (!submitted)
                    {
                        TrySubmit(verbose ? "ProcessInput(on NeedInput)" : null);
                        if (submitted && !waitForOutput)
                            break;
                    }
                }
                else if (type == MediaEventTypes.TransformHaveOutput)
                {
                    sawHave++;
                    produced = DrainOne() ?? produced;
                    if (produced is not null && waitForOutput)
                    {
                        _inputInFlight = false;
                        NoteLatency();
                        // Output may belong to a prior input; still return it (pipeline delay).
                        break;
                    }
                }
            }
        }

        void TrySubmit(string? logAs)
        {
            try
            {
                _transform.ProcessInput(0, sample, 0);
                submitted = true;
                _inputInFlight = true;
                _inFlightSinceMs = Environment.TickCount64;
                _submittedTs = System.Diagnostics.Stopwatch.GetTimestamp();
                _awaitingInput = false;
            }
            catch (SharpGenException ex)
            {
                if (logAs is not null)
                    Console.Error.WriteLine($"[mf] {logAs}: {ex.Message}");
            }
        }

        accepted = submitted;
        if (verbose && produced is null && (waitForOutput || !submitted))
            Console.Error.WriteLine($"[mf] async empty submitted={submitted} inFlight={_inputInFlight} need={sawNeed} have={sawHave}");
        return produced;
    }

    /// <summary><paramref name="budgetMs"/> 0: takes the events already queued, no waiting.</summary>
    private EncodedVideoFrame? DrainPending(int budgetMs)
    {
        var deadline = Environment.TickCount64 + budgetMs;
        EncodedVideoFrame? produced = null;
        while (Environment.TickCount64 <= deadline)
        {
            IMFMediaEvent? ev = null;
            try { ev = _events?.GetEvent(MfEventFlagNoWait); }
            catch { /* none */ }
            if (ev is null)
            {
                if (budgetMs <= 0) break;
                Thread.Sleep(1);
                continue;
            }
            using (ev)
            {
                if ((MediaEventTypes)ev.EventType == MediaEventTypes.TransformHaveOutput)
                {
                    produced = DrainOne() ?? produced;
                    if (produced is not null)
                        return produced;
                }
                else if ((MediaEventTypes)ev.EventType == MediaEventTypes.TransformNeedInput)
                    _awaitingInput = true;
            }
        }
        return produced;
    }

    private EncodedVideoFrame? DrainOne()
    {
        for (var i = 0; i < 4; i++)
        {
            var avcc = DrainOutput(out var keyframe, out var sets);
            if (sets is { Length: > 0 })
                _parameterSets = sets;
            if (avcc is null)
            {
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                    Console.Error.WriteLine("[mf] DrainOne: no sample");
                return null;
            }
            if (avcc.Length == 0)
            {
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                    Console.Error.WriteLine("[mf] DrainOne: empty avcc");
                continue;
            }

            if (keyframe && _parameterSets is null)
                _parameterSets = TryReadSequenceHeader();

            return new EncodedVideoFrame
            {
                Keyframe = keyframe,
                Avcc = avcc,
                ParameterSets = keyframe ? _parameterSets : null,
            };
        }
        return null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            if (_dxgiManager is not null)
                _transform.ProcessMessage(TMessageType.MessageSetD3DManager, UIntPtr.Zero);
        }
        catch { /* ignore */ }
        _gpuConv?.Dispose();
        _nv12Staging?.Dispose();
        _nv12Gpu?.Dispose();
        try { _inputSample?.Dispose(); } catch { /* ignore */ }
        try { _inputBuffer?.Dispose(); } catch { /* ignore */ }
        _inputSample = null;
        _inputBuffer = null;
        for (var i = 0; i < _ring.Length; i++)
        {
            try { _ring[i]?.Dispose(); } catch { /* ignore */ }
            try { _ringBuffers[i]?.Dispose(); } catch { /* ignore */ }
        }
        _dxgiManager?.Dispose();
        try { _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero); } catch { /* ignore */ }
        try { _transform.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero); } catch { /* ignore */ }
        _events?.Dispose();
        _transform.Dispose();
        ReleaseStartup();
    }

    private byte[]? DrainOutput(out bool keyframe, out byte[][]? sets)
    {
        keyframe = false;
        sets = null;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            IMFSample? owned = null;
            if (!_providesSamples)
            {
                owned = MediaFactory.MFCreateSample();
                var outBuf = MediaFactory.MFCreateMemoryBuffer(Math.Max(_outputBufferSize, _width * _height));
                owned.AddBuffer(outBuf);
                outBuf.Dispose();
            }

            var outData = new OutputDataBuffer { StreamID = 0, Sample = owned!, Status = 0 };
            var hr = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref outData, out _);
            if (hr.Failure)
            {
                owned?.Dispose();
                // Iris QSV: first HaveOutput often returns STREAM_CHANGE — renegotiate and retry.
                if (hr == Vortice.MediaFoundation.ResultCode.TransformStreamChange)
                {
                    if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                        Console.Error.WriteLine("[mf] ProcessOutput STREAM_CHANGE — renegotiate output");
                    try
                    {
                        using var avail = _transform.GetOutputAvailableType(0, 0);
                        _transform.SetOutputType(0, avail, 0);
                    }
                    catch (Exception ex)
                    {
                        if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                            Console.Error.WriteLine($"[mf] renegotiate failed: {ex.Message}");
                        return null;
                    }
                    continue;
                }
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal)
                    && attempt == 0)
                    Console.Error.WriteLine($"[mf] ProcessOutput fail hr=0x{hr.Code:X8} provides={_providesSamples}");
                if (hr == Vortice.MediaFoundation.ResultCode.TransformNeedMoreInput)
                    return null;
                continue;
            }

            var sample = outData.Sample ?? owned;
            if (sample is null)
            {
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                    Console.Error.WriteLine("[mf] ProcessOutput OK but sample null");
                continue;
            }

            try
            {
                byte[] annexB;
                try
                {
                    using var contig = sample.ConvertToContiguousBuffer();
                    contig.Lock(out var ptr, out _, out var len);
                    try
                    {
                        annexB = new byte[len];
                        Marshal.Copy(ptr, annexB, 0, len);
                    }
                    finally { contig.Unlock(); }
                }
                catch
                {
                    // Some HW samples expose a single buffer without ConvertToContiguousBuffer.
                    using var buf = sample.GetBufferByIndex(0);
                    buf.Lock(out var ptr, out _, out var len);
                    try
                    {
                        annexB = new byte[len];
                        Marshal.Copy(ptr, annexB, 0, Math.Min(len, buf.CurrentLength > 0 ? buf.CurrentLength : len));
                        if (buf.CurrentLength > 0 && buf.CurrentLength < annexB.Length)
                            Array.Resize(ref annexB, buf.CurrentLength);
                    }
                    finally { buf.Unlock(); }
                }

                // Keyframe = IDR NAL (type 5) only. SW MFT CleanPoint is unreliable
                // (often set on every sample) and would spam videoParams.
                var avcc = _codec == VideoCodec.hevc
                    ? AnnexBToHvcc(annexB, out var extracted, out var idr)
                    : AnnexBToAvcc(annexB, out extracted, out idr);
                keyframe = idr;
                if (extracted.Length > 0)
                    sets = extracted;
                return avcc;
            }
            finally
            {
                if (!ReferenceEquals(sample, owned))
                    sample.Dispose();
                owned?.Dispose();
            }
        }
        return null;
    }

    private byte[][]? TryReadSequenceHeader()
    {
        try
        {
            using var type = _transform.GetOutputCurrentType(0);
            var blob = type.GetBlob(MediaTypeAttributeKeys.MpegSequenceHeader);
            if (blob is null || blob.Length < 4) return null;
            byte[][] sets;
            if (_codec == VideoCodec.hevc) _ = AnnexBToHvcc(blob, out sets, out _);
            else _ = AnnexBToAvcc(blob, out sets, out _);
            return sets.Length > 0 ? sets : null;
        }
        catch { return null; }
    }

    private static IMFTransform? ActivateEncoder(
        EnumFlag flags, int w, int h, int bitrate, double fps, IMFDXGIDeviceManager? dxgi,
        out string label, bool hardwareOnly, out bool async, VideoCodec codec, bool tenBit)
    {
        label = "none";
        async = (flags & EnumFlag.EnumFlagAsyncmft) != 0;
        var outputInfo = new RegisterTypeInfo
        {
            GuidMajorType = MediaTypeGuids.Video,
            GuidSubtype = codec == VideoCodec.hevc ? VideoFormatGuids.Hevc : VideoFormatGuids.H264,
        };

        using var activates = MediaFactory.MFTEnumEx(
            TransformCategoryGuids.VideoEncoder, (uint)flags, null, outputInfo);

        foreach (var activate in activates)
        {
            using (activate)
            {
                string name = "h264";
                try
                {
                    var friendly = activate.GetAllocatedString(TransformAttributeKeys.MftFriendlyNameAttribute);
                    if (!string.IsNullOrEmpty(friendly)) name = friendly;
                }
                catch { /* optional */ }

                var isHw = name.Contains("Quick Sync", StringComparison.OrdinalIgnoreCase)
                           || name.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase)
                           || name.Contains("AMD", StringComparison.OrdinalIgnoreCase)
                           || name.Contains("DX12", StringComparison.OrdinalIgnoreCase)
                           || name.Contains("Intel", StringComparison.OrdinalIgnoreCase);
                if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                    Console.Error.WriteLine($"[mf] candidate '{name}' isHw={isHw} wantHw={hardwareOnly} dxgi={(dxgi is not null)}");
                if (hardwareOnly && !isHw) continue;
                if (!hardwareOnly && isHw) continue;

                IMFTransform? transform = null;
                try
                {
                    transform = activate.ActivateObject<IMFTransform>();
                    // QSV/DX12 are async MFTs even when enumerated as sync — unlock first.
                    try { transform.Attributes.Set(TransformAttributeKeys.TransformAsyncUnlock, true); }
                    catch { /* optional */ }
                    // DXGI manager must be set before media types for D3D-aware HW MFTs.
                    if (dxgi is not null)
                    {
                        try { transform.Attributes.Set(TransformAttributeKeys.D3DAware, true); } catch { /* optional */ }
                        try { transform.Attributes.Set(TransformAttributeKeys.D3D11Aware, true); } catch { /* optional */ }
                        transform.ProcessMessage(
                            TMessageType.MessageSetD3DManager,
                            (UIntPtr)(nuint)dxgi.NativePointer);
                    }
                    ConfigureNv12(transform, w, h, bitrate, fps, codec, tenBit);
                    CodecApi.ApplyLowLatency(transform, bitrate);
                    transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
                    transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
                    label = name;
                    // Hardware MFTs from the hardware enum are async event-driven even if
                    // EnumFlagSyncmft was requested — always pump events when unlocked async.
                    async = hardwareOnly || async;
                    return transform;
                }
                catch (Exception ex)
                {
                    if (string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal))
                        Console.Error.WriteLine($"[mf] activate '{name}' failed: {ex.GetType().Name}: {ex.Message}");
                    transform?.Dispose();
                }
            }
        }
        return null;
    }

    private static void ConfigureNv12(IMFTransform transform, int w, int h, int bitrate, double fps,
        VideoCodec codec, bool tenBit)
    {
        using var outType = transform.GetOutputAvailableType(0, 0);
        outType.Set(MediaTypeAttributeKeys.FrameSize, PackSize(w, h));
        outType.Set(MediaTypeAttributeKeys.FrameRate, PackRate(fps));
        outType.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrate);
        outType.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        // Soft hint for SW MFT (~0.5s GOP at 30fps). CodecAPI reinforces after types are set.
        // Shorter GOP → first IDR after browser/scene cut arrives sooner on SW MFT.
        try { outType.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, 8u); } catch { /* optional */ }
        // HEVC profile: eAVEncH265VProfile_Main_420_8 = 1, Main_420_10 = 2.
        if (codec == VideoCodec.hevc)
            outType.Set(MediaTypeAttributeKeys.Mpeg2Profile, tenBit ? 2u : 1u);
        transform.SetOutputType(0, outType, 0);

        IMFMediaType? nv = null;
        for (var i = 0; i < 8; i++)
        {
            var avail = transform.GetInputAvailableType(0, i);
            if (avail.GetGUID(MediaTypeAttributeKeys.Subtype) == (tenBit ? VideoFormatGuids.P010 : VideoFormatGuids.NV12))
            {
                nv = avail;
                break;
            }
            avail.Dispose();
        }
        if (nv is null)
            throw new InvalidOperationException(tenBit ? "encoder has no P010 input" : "encoder has no NV12 input");

        using (nv)
        {
            nv.Set(MediaTypeAttributeKeys.FrameSize, PackSize(w, h));
            nv.Set(MediaTypeAttributeKeys.FrameRate, PackRate(fps));
            nv.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            transform.SetInputType(0, nv, 0);
        }
    }

    private IMFSample CreateNv12Sample(byte[] nv12, int w, int h, long time, long duration)
    {
        _ = (w, h);
        if (_inputBuffer is null || _inputSample is null)
        {
            _inputBuffer?.Dispose();
            _inputSample?.Dispose();
            _inputBuffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
            _inputSample = MediaFactory.MFCreateSample();
            _inputSample.AddBuffer(_inputBuffer);
        }
        _inputBuffer.Lock(out var ptr, out _, out _);
        try { Marshal.Copy(nv12, 0, ptr, nv12.Length); }
        finally { _inputBuffer.Unlock(); }
        _inputBuffer.CurrentLength = nv12.Length;
        _inputSample.SampleTime = time;
        _inputSample.SampleDuration = duration;
        return _inputSample;
    }

    /// <summary>QSV/NVENC path: upload NV12 into a DXGI texture and wrap as an MF sample.</summary>
    private IMFSample CreateDxgiNv12Sample(byte[] nv12, int w, int h, long time, long duration)
    {
        EnsureDxgiTextures();
        var ctx = _d3d!.Context;
        var mapped = ctx.Map(_nv12Staging!, 0, MapMode.Write, MapFlags.None);
        try
        {
            var pitch = (int)mapped.RowPitch;
            // Y plane
            for (var y = 0; y < h; y++)
                Marshal.Copy(nv12, y * w, mapped.DataPointer + y * pitch, w);
            // UV plane (interleaved) starts after Y in NV12 system buffer.
            var uvSrc = w * h;
            var uvDst = mapped.DataPointer + h * pitch;
            for (var y = 0; y < h / 2; y++)
                Marshal.Copy(nv12, uvSrc + y * w, uvDst + y * pitch, w);
        }
        finally
        {
            ctx.Unmap(_nv12Staging!, 0);
        }
        ctx.CopyResource(_nv12Gpu!, _nv12Staging!);

        using var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(
            typeof(ID3D11Texture2D).GUID, _nv12Gpu!, 0, false);
        var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = time;
        sample.SampleDuration = duration;
        return sample;
    }

    private void EnsureDxgiTextures()
    {
        if (_nv12Gpu is not null) return;
        var desc = new Texture2DDescription
        {
            Width = (uint)_width,
            Height = (uint)_height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.None,
            CPUAccessFlags = CpuAccessFlags.None,
            MiscFlags = ResourceOptionFlags.None,
        };
        // QSV often rejects BindFlags.None; try encode-friendly RT+SRV, then bare.
        Exception? last = null;
        foreach (var bind in new[]
                 {
                     BindFlags.ShaderResource | BindFlags.RenderTarget,
                     BindFlags.None,
                 })
        {
            try
            {
                desc.BindFlags = bind;
                desc.Usage = ResourceUsage.Default;
                desc.CPUAccessFlags = CpuAccessFlags.None;
                _nv12Gpu = _d3d!.Device.CreateTexture2D(desc);
                desc.Usage = ResourceUsage.Staging;
                desc.BindFlags = BindFlags.None;
                desc.CPUAccessFlags = CpuAccessFlags.Write;
                _nv12Staging = _d3d.Device.CreateTexture2D(desc);
                last = null;
                break;
            }
            catch (Exception ex)
            {
                last = ex;
                _nv12Gpu?.Dispose();
                _nv12Staging?.Dispose();
                _nv12Gpu = null;
                _nv12Staging = null;
            }
        }
        if (_nv12Gpu is null || _nv12Staging is null)
            throw last ?? new InvalidOperationException("NV12 DXGI textures unavailable");
    }

    private static byte[] ScaleBgra(byte[] src, int sw, int sh, int dw, int dh, ref byte[]? scratch)
    {
        if (sw == dw && sh == dh) return src;
        var need = dw * dh * 4;
        if (scratch is null || scratch.Length != need)
            scratch = new byte[need];
        var dst = scratch;
        Parallel.For(0, dh, y =>
        {
            var sy = y * sh / dh;
            var diBase = y * dw * 4;
            for (var x = 0; x < dw; x++)
            {
                var sx = x * sw / dw;
                var si = (sy * sw + sx) * 4;
                var di = diBase + x * 4;
                dst[di] = src[si];
                dst[di + 1] = src[si + 1];
                dst[di + 2] = src[si + 2];
                dst[di + 3] = src[si + 3];
            }
        });
        return dst;
    }

    /// <summary>
    /// BGRA -> P010 (10-bit 4:2:0, Y plane then interleaved UV, each sample a little-endian word with the 10 bits in
    /// the high bits), BT.709 video range: Y 64..940, Cb/Cr 64..960 centred on 512 - the range the Mac receiver
    /// assumes for Main10 (StreamRenderer.videoRange(tenBit:)). The source is 8-bit, so this adds no detail; the
    /// 10-bit encode avoids banding and quantisation steps in gradients and matches what the Mac Sender sends.
    /// </summary>
    internal static void BgraToP010(byte[] bgra, int w, int h, byte[] p010)
    {
        var ySizeBytes = w * h * 2;
        Parallel.For(0, h, y =>
        {
            var row = y * w;
            for (var x = 0; x < w; x++)
            {
                var i = (row + x) * 4;
                int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                var yy = 64 + ((187 * r + 629 * g + 63 * b + 128) >> 8);
                yy = Math.Clamp(yy, 64, 940) << 6;
                var o = (row + x) * 2;
                p010[o] = (byte)yy;
                p010[o + 1] = (byte)(yy >> 8);
            }
        });
        Parallel.For(0, h / 2, y2 =>
        {
            var y = y2 * 2;
            var uvRow = ySizeBytes + y2 * w * 2;
            for (var x = 0; x < w; x += 2)
            {
                int b = 0, g = 0, r = 0;
                for (var dy = 0; dy < 2; dy++)
                for (var dx = 0; dx < 2; dx++)
                {
                    var i = ((y + dy) * w + (x + dx)) * 4;
                    b += bgra[i]; g += bgra[i + 1]; r += bgra[i + 2];
                }
                b >>= 2; g >>= 2; r >>= 2;
                var cb = Math.Clamp(512 + ((-103 * r - 347 * g + 450 * b + 128) >> 8), 64, 960) << 6;
                var cr = Math.Clamp(512 + ((450 * r - 409 * g - 41 * b + 128) >> 8), 64, 960) << 6;
                var o = uvRow + x * 2;
                p010[o] = (byte)cb;
                p010[o + 1] = (byte)(cb >> 8);
                p010[o + 2] = (byte)cr;
                p010[o + 3] = (byte)(cr >> 8);
            }
        });
    }

    internal static void BgraToNv12(byte[] bgra, int w, int h, byte[] nv12)
    {
        var ySize = w * h;
        Parallel.For(0, h, y =>
        {
            var row = y * w;
            for (var x = 0; x < w; x++)
            {
                var i = (row + x) * 4;
                int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                // BT.709 video range (the receiver decodes video as BT.709; BT.601 shifted colours vs the tiles)
                var Y = ((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
                nv12[row + x] = (byte)Math.Clamp(Y, 0, 255);
            }
        });
        Parallel.For(0, h / 2, y2 =>
        {
            var y = y2 * 2;
            var uvRow = ySize + y2 * w;
            for (var x = 0; x < w; x += 2)
            {
                long b = 0, g = 0, r = 0;
                for (var dy = 0; dy < 2; dy++)
                for (var dx = 0; dx < 2; dx++)
                {
                    var i = ((y + dy) * w + (x + dx)) * 4;
                    b += bgra[i]; g += bgra[i + 1]; r += bgra[i + 2];
                }
                b /= 4; g /= 4; r /= 4;
                var U = ((-26 * (int)r - 87 * (int)g + 112 * (int)b + 128) >> 8) + 128;
                var V = ((112 * (int)r - 102 * (int)g - 10 * (int)b + 128) >> 8) + 128;
                nv12[uvRow + x] = (byte)Math.Clamp(U, 0, 255);
                nv12[uvRow + x + 1] = (byte)Math.Clamp(V, 0, 255);
            }
        });
    }

    private static ulong PackSize(int width, int height) => ((ulong)(uint)width << 32) | (uint)height;
    private static ulong PackRate(double fps) => ((ulong)(uint)Math.Max(1, Math.Round(fps)) << 32) | 1;

    /// <summary>
    /// slice_type (0..9) of the first VCL NAL in an AVCC buffer, or -1. I slices are 2/4/7/9.
    /// Used to tell an intra picture apart from a P picture when the encoder emits non-IDR I frames.
    /// </summary>
    internal static int FirstSliceType(byte[] avcc)
    {
        if (avcc.Length < 6) return -1;
        // Skip the 4-byte length and the 1-byte NAL header, then read two Exp-Golomb values:
        // first_mb_in_slice, slice_type. Emulation-prevention bytes are ignored (header is tiny).
        var bitPos = 0;
        int ReadBit() { var b = (avcc[5 + (bitPos >> 3)] >> (7 - (bitPos & 7))) & 1; bitPos++; return b; }
        int ReadUe()
        {
            var zeros = 0;
            while (zeros < 16 && ReadBit() == 0) zeros++;
            if (zeros == 0) return 0;
            var v = 0;
            for (var i = 0; i < zeros; i++) v = (v << 1) | ReadBit();
            return (1 << zeros) - 1 + v;
        }
        try { ReadUe(); return ReadUe(); }
        catch (IndexOutOfRangeException) { return -1; }
    }

    /// <summary>
    /// HEVC Annex-B to length-prefixed NALs (hvcC samples). Parameter sets VPS/SPS/PPS (32/33/34) are
    /// returned separately; AUD/SEI are dropped; hasIdr = IDR_W_RADL or IDR_N_LP.
    /// </summary>
    internal static byte[] AnnexBToHvcc(byte[] annexB, out byte[][] parameterSets, out bool hasIdr)
    {
        var nals = new List<byte[]>();
        var sets = new List<byte[]>();
        hasIdr = false;
        var i = 0;
        while (i < annexB.Length)
        {
            var sc = StartCodeLen(annexB, i);
            if (sc == 0) { i++; continue; }
            var start = i + sc;
            var next = FindNextStartCode(annexB, start);
            var len = next - start;
            if (len > 1)
            {
                var nal = new byte[len];
                Buffer.BlockCopy(annexB, start, nal, 0, len);
                var t = (nal[0] >> 1) & 0x3F;
                if (t is 32 or 33 or 34) sets.Add(nal);
                else if (t < 32) // VCL only: drop AUD (35) and SEI (39, 40)
                {
                    if (t is 19 or 20) hasIdr = true;
                    nals.Add(nal);
                }
            }
            i = next;
        }
        parameterSets = sets.ToArray();
        var total = nals.Sum(n => 4 + n.Length);
        var hvcc = new byte[total];
        var o = 0;
        foreach (var nal in nals)
        {
            hvcc[o++] = (byte)(nal.Length >> 24);
            hvcc[o++] = (byte)(nal.Length >> 16);
            hvcc[o++] = (byte)(nal.Length >> 8);
            hvcc[o++] = (byte)nal.Length;
            Buffer.BlockCopy(nal, 0, hvcc, o, nal.Length);
            o += nal.Length;
        }
        return hvcc;
    }

    internal static byte[] AnnexBToAvcc(byte[] annexB, out byte[][] parameterSets) =>
        AnnexBToAvcc(annexB, out parameterSets, out _);

    internal static byte[] AnnexBToAvcc(byte[] annexB, out byte[][] parameterSets, out bool hasIdr)
    {
        var nals = new List<byte[]>();
        var sets = new List<byte[]>();
        hasIdr = false;
        var i = 0;
        while (i < annexB.Length)
        {
            var sc = StartCodeLen(annexB, i);
            if (sc == 0) { i++; continue; }
            var start = i + sc;
            var next = FindNextStartCode(annexB, start);
            var len = next - start;
            if (len > 0)
            {
                var nal = new byte[len];
                Buffer.BlockCopy(annexB, start, nal, 0, len);
                var t = (byte)(nal[0] & 0x1F);
                if (t is 7 or 8) sets.Add(nal);
                else if (t is 1 or 5) // VCL only — drop AUD/SEI (VT often rejects them)
                {
                    if (t == 5) hasIdr = true;
                    nals.Add(nal);
                }
            }
            i = next;
        }

        parameterSets = sets.ToArray();
        var total = nals.Sum(n => 4 + n.Length);
        var avcc = new byte[total];
        var o = 0;
        foreach (var nal in nals)
        {
            avcc[o++] = (byte)(nal.Length >> 24);
            avcc[o++] = (byte)(nal.Length >> 16);
            avcc[o++] = (byte)(nal.Length >> 8);
            avcc[o++] = (byte)nal.Length;
            Buffer.BlockCopy(nal, 0, avcc, o, nal.Length);
            o += nal.Length;
        }
        return avcc;
    }

    private static int FindNextStartCode(byte[] data, int from)
    {
        for (var i = from; i + 2 < data.Length; i++)
            if (StartCodeLen(data, i) > 0) return i;
        return data.Length;
    }

    private static int StartCodeLen(byte[] data, int i)
    {
        if (i + 3 < data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            return 4;
        if (i + 2 < data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            return 3;
        return 0;
    }

    private static void EnsureStartup()
    {
        if (Interlocked.Increment(ref _mfRefs) == 1)
            MediaFactory.MFStartup(true).CheckError();
    }

    private static void ReleaseStartup()
    {
        if (Interlocked.Decrement(ref _mfRefs) == 0)
            MediaFactory.MFShutdown();
    }
}
