using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Afterscreen.Sender.Capture;

/// <summary>
/// The Windows counterpart of the Mac <c>AudioTap</c>: everything the default output device plays, captured through WASAPI loopback
/// as interleaved 16-bit PCM in packets of about 10 ms (the receiver's 30 ms buffer expects that order). Float samples are clipped
/// to +-1; more than two channels are folded to stereo (the receiver plays 1-2).
/// <para>
/// WASAPI often delivers several packets at once. Emitting them immediately makes the receiver's jitter buffer oscillate between
/// catch-up and hold-back (0.2% speed), which sounds like continuous pitch distortion rather than dropouts. A gentle realtime
/// pacer emits one packet per packet-duration with a 1 ms timer period and spin waits — no mid-stream drops, no burst catch-up.
/// Keep audio on the cursor channel so it is not stuck behind multi‑MB video writes on the main link.
/// </para>
/// </summary>
public sealed class AudioLoopback : IDisposable
{
    public delegate void Handler(int sampleRate, int channels, short[] samples);

    private readonly record struct PacePacket(int Rate, int Channels, short[] Samples);

    private const int PacketFrames = 512; // ~10 ms at 48 kHz — same as Mac AudioTap
    private const int PrebufferPackets = 3; // ~30 ms — matches receiver target
    private const int MaxPacePackets = 40; // ~400 ms safety only

    private readonly Handler _onSamples;
    private readonly WasapiLoopbackCapture? _capture;
    private readonly ProcessLoopbackCapture? _processCapture;
    private readonly MMDevice _device;
    private readonly int _channelsIn;
    private readonly int _channelsOut;
    private readonly bool _float;
    private readonly int _sampleRate;
    private readonly int _bytesPerSample;
    private readonly ConcurrentQueue<PacePacket> _paceQ = new();
    private readonly AutoResetEvent _pacePulse = new(false);
    private readonly Thread _paceThread;
    private int _paceCount;
    private volatile bool _paceRun = true;
    private bool _disposed;

    public string DeviceId => _device.ID;
    public string DeviceName => _device.FriendlyName;
    public int SampleRate => _sampleRate;
    public int Channels => _channelsOut;
    /// <summary>True when capture survives endpoint mute (process loopback) — Mac mutedWhenTapped.</summary>
    public bool EndpointMuteSafe { get; }

    /// <summary>Raised when the device goes away (unplugged, disabled) - the capture must be rebuilt on the new default.</summary>
    public event Action? Stopped;

    private AudioLoopback(MMDevice device, Handler onSamples, ProcessLoopbackCapture process)
    {
        _device = device;
        _onSamples = onSamples;
        _processCapture = process;
        EndpointMuteSafe = true;
        var f = process.WaveFormat;
        _sampleRate = f.SampleRate;
        _channelsIn = f.Channels;
        _channelsOut = Math.Min(2, f.Channels);
        _float = false;
        _bytesPerSample = Math.Max(1, f.BitsPerSample / 8);
        process.DataAvailable += OnData;
        process.RecordingStopped += (_, _) => { if (!_disposed) Stopped?.Invoke(); };
        _paceThread = StartPacer();
        Console.WriteLine($"[audio] capture process-loopback {f.SampleRate} Hz {f.Channels}ch {f.BitsPerSample}bit pcm (mute-safe)");
    }

    private AudioLoopback(MMDevice device, Handler onSamples)
    {
        _device = device;
        _onSamples = onSamples;
        EndpointMuteSafe = false;
        _capture = new WasapiLoopbackCapture(device);
        var f = _capture.WaveFormat;
        _sampleRate = f.SampleRate;
        _channelsIn = f.Channels;
        _channelsOut = Math.Min(2, f.Channels);
        _float = f.Encoding == WaveFormatEncoding.IeeeFloat
            || (f is WaveFormatExtensible ext
                && ext.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        _bytesPerSample = _float ? 4 : Math.Max(1, f.BitsPerSample / 8);
        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += (_, _) => { if (!_disposed) Stopped?.Invoke(); };
        _paceThread = StartPacer();
        Console.WriteLine($"[audio] capture {f.SampleRate} Hz {f.Channels}ch {f.BitsPerSample}bit {f.Encoding} float={_float}");
    }

    private Thread StartPacer()
    {
        // BelowNormal: Normal+1ms wakeups were starving DXGI capture (sound-on → frozen picture).
        var t = new Thread(PaceLoop)
        {
            IsBackground = true,
            Name = "afterscreen-audio-pace",
            Priority = ThreadPriority.BelowNormal,
        };
        t.Start();
        return t;
    }

    /// <summary>Starts capturing the default output device; null when there is none or it cannot be opened.</summary>
    public static AudioLoopback? TryStart(Handler onSamples)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            // Prefer process loopback so endpoint mute (Mac mutedWhenTapped) does not zero capture.
            var process = ProcessLoopbackCapture.TryStart((uint)Environment.ProcessId);
            if (process is not null)
            {
                var tap = new AudioLoopback(device, onSamples, process);
                process.StartRecording();
                return tap;
            }
            var endpoint = new AudioLoopback(device, onSamples);
            endpoint._capture!.StartRecording();
            return endpoint;
        }
        catch (Exception ex)
        {
            Console.WriteLine("[audio] cannot capture the output: " + ex.Message);
            return null;
        }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded <= 0 || !_paceRun) return;
        var frames = e.BytesRecorded / (_bytesPerSample * _channelsIn);
        if (frames <= 0) return;
        var wave = new WaveBuffer(e.Buffer);
        for (var start = 0; start < frames; start += PacketFrames)
        {
            var n = Math.Min(PacketFrames, frames - start);
            if (n <= 0) break;
            var outBuf = new short[n * _channelsOut];
            for (var i = 0; i < n; i++)
            {
                var frameBase = start + i;
                for (var c = 0; c < _channelsOut; c++)
                    outBuf[i * _channelsOut + c] = ToShort(Fold(wave, frameBase, c));
            }
            while (Volatile.Read(ref _paceCount) >= MaxPacePackets && _paceQ.TryDequeue(out _))
                Interlocked.Decrement(ref _paceCount);
            _paceQ.Enqueue(new PacePacket(_sampleRate, _channelsOut, outBuf));
            Interlocked.Increment(ref _paceCount);
            _pacePulse.Set();
        }
    }

    private void PaceLoop()
    {
        try { _ = NativeMethods.timeBeginPeriod(1); } catch { /* older OS */ }
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var nextMs = 0.0;
        var primed = false;
        try
        {
            while (_paceRun)
            {
                if (!primed)
                {
                    if (Volatile.Read(ref _paceCount) < PrebufferPackets)
                    {
                        _pacePulse.WaitOne(5);
                        continue;
                    }
                    primed = true;
                    nextMs = sw.Elapsed.TotalMilliseconds;
                    Console.WriteLine($"[audio] pace primed ({PrebufferPackets} pkt @ {_sampleRate} Hz)");
                }

                if (!_paceQ.TryDequeue(out var pkt))
                {
                    _pacePulse.WaitOne(5);
                    // Hold the schedule — do not pull nextMs forward into a burst when data resumes.
                    continue;
                }
                Interlocked.Decrement(ref _paceCount);

                try { _onSamples(pkt.Rate, pkt.Channels, pkt.Samples); }
                catch (Exception ex) { Console.WriteLine("[audio] pace: " + ex.Message); }

                var frames = pkt.Channels > 0 ? pkt.Samples.Length / pkt.Channels : PacketFrames;
                var tickMs = frames * 1000.0 / Math.Max(1, pkt.Rate);
                nextMs += tickMs;
                WaitUntil(sw, nextMs);
                // Late: slip the clock — never dump queued PCM (that punches holes / warps pitch).
                var now = sw.Elapsed.TotalMilliseconds;
                if (now > nextMs + tickMs * 0.5)
                    nextMs = now;
            }
        }
        finally
        {
            try { _ = NativeMethods.timeEndPeriod(1); } catch { /* ignore */ }
        }
    }

    private static void WaitUntil(System.Diagnostics.Stopwatch sw, double nextMs)
    {
        for (;;)
        {
            var delay = nextMs - sw.Elapsed.TotalMilliseconds;
            if (delay <= 0) return;
            // One bulk Sleep for most of the wait — Sleep(1)×N at 1 ms timer period burned CPU
            // and starved DXGI (sound-on → cap ~10 fps / frozen picture). Emit slightly early
            // rather than spin the last sub-ms.
            if (delay >= 2.0)
            {
                Thread.Sleep((int)Math.Floor(delay - 0.5));
                continue;
            }
            if (delay > 0.75) Thread.Sleep(1);
            return;
        }
    }

    private float Sample(WaveBuffer wave, int frame, int channel)
    {
        var i = frame * _channelsIn + channel;
        if (_float) return wave.FloatBuffer[i];
        return _bytesPerSample == 2 ? wave.ShortBuffer[i] / 32768f
            : wave.IntBuffer[i] / 2147483648f;
    }

    private float Fold(WaveBuffer wave, int frame, int c)
    {
        if (_channelsIn <= 2) return Sample(wave, frame, c);
        var front = Sample(wave, frame, c);
        var centre = _channelsIn > 2 ? Sample(wave, frame, 2) * 0.707f : 0;
        var back = _channelsIn > 5 ? Sample(wave, frame, 4 + c) * 0.707f : 0;
        var side = _channelsIn > 7 ? Sample(wave, frame, 6 + c) * 0.707f : 0;
        return (front + centre + back + side) * 0.6f;
    }

    /// <summary>Linear in ±1 (Mac); soft-clip only the rare peaks above full scale from OS enhancements.</summary>
    private static short ToShort(float x)
    {
        if (float.IsNaN(x) || float.IsInfinity(x)) return 0;
        if (x > 1f || x < -1f)
            x = MathF.Tanh(x);
        return (short)Math.Round(Math.Clamp(x, -1f, 1f) * 32767f);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _paceRun = false;
        _pacePulse.Set();
        try { _capture?.StopRecording(); } catch { /* already stopped */ }
        try { _processCapture?.StopRecording(); } catch { /* already stopped */ }
        try { _paceThread.Join(500); } catch { /* ignore */ }
        _capture?.Dispose();
        _processCapture?.Dispose();
        _device.Dispose();
        _pacePulse.Dispose();
        while (_paceQ.TryDequeue(out _)) { }
    }

    private static class NativeMethods
    {
        [DllImport("winmm.dll")]
        public static extern uint timeBeginPeriod(uint period);

        [DllImport("winmm.dll")]
        public static extern uint timeEndPeriod(uint period);
    }
}

/// <summary>The PC's output level, as the Mac popover's volume slider shows and sets it (and what the receiver follows).</summary>
public static class SystemAudio
{
    public readonly record struct Level(float Volume, bool Muted);

    public static Level? GetLevel()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var v = device.AudioEndpointVolume;
            return new Level(v.MasterVolumeLevelScalar, v.Mute);
        }
        catch { return null; }
    }

    public static void SetVolume(float volume)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            device.AudioEndpointVolume.MasterVolumeLevelScalar = Math.Clamp(volume, 0f, 1f);
            if (volume > 0) device.AudioEndpointVolume.Mute = false;
        }
        catch { /* no endpoint */ }
    }

    /// <summary>Endpoint mute only (Mac tap mute analogue). Returns previous mute, or null on failure.</summary>
    public static bool? TrySetMute(bool muted)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var v = device.AudioEndpointVolume;
            var prev = v.Mute;
            v.Mute = muted;
            return prev;
        }
        catch { return null; }
    }

    public static string? DefaultDeviceId()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return device.ID;
        }
        catch { return null; }
    }

    public static bool OutputIsHeadphones()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var name = device.FriendlyName + " " + device.DeviceFriendlyName;
            string[] marks = { "headphone", "headset", "earphone", "earbud", "airpods", "hands-free", "헤드폰", "헤드셋", "이어폰", "블루투스" };
            return marks.Any(m => name.Contains(m, StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }
}
