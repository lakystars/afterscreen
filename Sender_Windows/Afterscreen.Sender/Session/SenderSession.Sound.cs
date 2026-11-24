using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;

namespace Afterscreen.Sender.Session;

public sealed partial class SenderSession
{
    /// <summary>Mac "Play on receiver": the PC's sound goes to the receiver (session only: idle has no receiver to play on).</summary>
    public bool Sound { get; set; }

    /// <summary>
    /// Mac <c>ownBrightness</c>: non-null = manual receiver level; null = follow the PC panel (Mac brightnessFollows).
    /// </summary>
    public double? OwnBrightness { get; set; } = 0.8;

    /// <summary>Mac <c>brightnessOffsets</c>: stops by receiver ID while following.</summary>
    public Dictionary<string, double> BrightnessOffsets { get; set; } = new();

    private AudioLoopback? _audio;
    private Timer? _soundTimer;
    private Timer? _brightnessTimer;
    private string? _soundDevice;
    private SystemAudio.Level? _sentLevel;
    private double? _brightnessSent;
    private long _audioPackets;
    private long _audioReportAt;
    private int _audioGen; // bumps on intentional stop so dispose Stopped does not clear a newer tap
    // System.Threading.Timer can overlap callbacks; overlapping TryStart left two pacers → choppy RX after OFF→ON.
    private int _soundTickBusy;
    private int _soundEpoch; // bumps on StopSound so a late tick cannot resurrect capture
    private long _audioDevicePollAt;
    private long _audioLevelPollAt;
    private bool _cachedHeadphones;
    private string? _cachedDeviceId;
    // Mac muteWhenTapped: mute PC speakers while tapped. Must not tell the receiver we are muted
    // (it would silence playback). Always verify loopback still has signal after muting.
    private bool _localHandoffMute;
    private bool _logicalMuted; // user's mute before handoff — what the receiver follows
    private bool _localMuteUnsupported;
    private int _mutePhase; // 0 idle, 1 wait-signal, 2 verify-after-mute
    private int _muteWaitLeft;
    private int _muteSettleLeft; // packets to ignore right after mute (residual PCM)
    private int _muteGoodPackets; // packets with real peak after settle
    private long _mutePhaseAt; // wall clock so we roll back if OnAudio stalls
    /// <summary>Set after local-mute rollback so SoundTick re-reads level (stale Mute=true would silence RX).</summary>
    private int _volumeResync;

    public void SetBrightnessOffsets(Dictionary<string, double> offsets)
    {
        BrightnessOffsets = offsets;
        _brightnessSent = null;
        if (Snapshot.Phase == SessionPhase.Streaming && !TestMode)
            FollowBrightness();
    }

    public void SetSound(bool on)
    {
        Sound = on;
        if (Snapshot.Phase != SessionPhase.Streaming || TestMode) return;
        if (on) StartSound(); else StopSound();
    }

    /// <summary>Mac <c>setReceiverBrightness</c>: null follows the PC panel; otherwise the receiver takes this level.</summary>
    public void SetReceiverBrightness(double? level)
    {
        OwnBrightness = level is { } v ? Math.Clamp(v, 0, 1) : null;
        _brightnessSent = null;
        if (Snapshot.Phase == SessionPhase.Streaming && !TestMode)
            FollowBrightness();
    }

    /// <summary>Mac 5 Hz panel poll while streaming.</summary>
    private void StartBrightnessFollow()
    {
        lock (this)
        {
            if (_brightnessTimer is not null) return;
            _brightnessTimer = new Timer(_ => FollowBrightness(), null, 0, 200);
        }
    }

    private void StopBrightnessFollow()
    {
        Timer? t;
        lock (this) { t = _brightnessTimer; _brightnessTimer = null; }
        t?.Dispose();
        _brightnessSent = null;
    }

    /// <summary>Mac <c>followBrightness</c>: manual OwnBrightness, else WMI panel level.</summary>
    private void FollowBrightness()
    {
        try
        {
            if (Snapshot.Phase != SessionPhase.Streaming || TestMode) return;
            var panel = PanelBrightness.TryRead();
            if (Snapshot.MacBrightness != panel)
            {
                Snapshot.MacBrightness = panel;
                Publish();
            }
            if (OwnBrightness is { } own)
            {
                SendBrightness(own, force: false);
                return;
            }
            if (panel is null)
            {
                _brightnessSent = null; // resent once the panel reads again
                return;
            }
            // Mac followedLight without peak nits: level only, with per-receiver stops.
            var stops = 0.0;
            if (Snapshot.Peer?.ReceiverID is { Length: > 0 } id
                && BrightnessOffsets.TryGetValue(id, out var s))
                stops = s;
            // Dev override for console live tests (App uses BrightnessOffsets).
            if (double.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_BRIGHTNESS_OFFSET"),
                    System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out var envStops))
                stops = BrightnessOffset.Snapped(envStops);
            SendBrightness(BrightnessOffset.Level(panel.Value, stops), force: false);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[brightness] " + ex.Message);
        }
    }

    private void SendBrightness(double level, bool force)
    {
        if (!force && _brightnessSent is { } sent && Math.Abs(sent - level) < 0.004) return;
        try
        {
            // Mac: main connection only. Cursor-channel messages are ignored for .brightness on the receiver.
            var conn = _conn;
            if (conn is null) return;
            conn.Send(new Message(MessageType.Brightness, 0, BrightnessWire.Encode(new PanelLight(null, level))));
            _brightnessSent = level;
            if (force || Environment.GetEnvironmentVariable("AFTERSCREEN_BRIGHTNESS") == "1")
                Console.WriteLine($"[brightness] sent level={level:0.00} follow={OwnBrightness is null}");
        }
        catch { /* ignore */ }
    }

    /// <summary>Starts the loopback capture and the output-level watcher; no-op without receiver support or on headphones.</summary>
    private void StartSound()
    {
        if (Snapshot.Peer is not { AudioPlayback: true })
        {
            Snapshot.SoundOnReceiver = false;
            Publish();
            return;
        }
        lock (this)
        {
            // Timer owns TryStart — do not gate on _audio (a raced tick could leave an orphan tap).
            if (_soundTimer is not null) return;
            // Timer only — do not run WASAPI start on the UI/caller thread (can hitch DXGI).
            _soundTimer = new Timer(_ => SoundTick(), null, 50, 200);
        }
    }

    /// <summary>Every 0.2 s: follow the default output device, hand over / take back the sound, send the PC's volume and mute.</summary>
    private void SoundTick()
    {
        // One tick at a time: period callbacks overlap when TryStart/Dispose runs long.
        if (Interlocked.CompareExchange(ref _soundTickBusy, 1, 0) != 0) return;
        var epoch = Volatile.Read(ref _soundEpoch);
        try
        {
            if (!Sound || Snapshot.Phase != SessionPhase.Streaming) return;
            lock (this)
            {
                if (_soundTimer is null || epoch != _soundEpoch) return;
            }
            // AFTERSCREEN_SOUND_FORCE=1: ignore headphones/Bluetooth detection (local soak / A/B).
            var force = Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_FORCE") == "1";
            // Cache device/headphones ~1 s and level ~400 ms — enumerator every 200 ms hitch DXGI.
            var now = Environment.TickCount64;
            bool pollDevice, pollLevel;
            lock (this)
            {
                if (_soundTimer is null || epoch != _soundEpoch) return;
                pollDevice = now - _audioDevicePollAt > 1000 || _cachedDeviceId is null;
                pollLevel = now - _audioLevelPollAt > 400;
            }
            bool headphones;
            string? device;
            SystemAudio.Level? level = null;
            if (pollDevice)
            {
                headphones = !force && SystemAudio.OutputIsHeadphones();
                device = SystemAudio.DefaultDeviceId();
            }
            else
            {
                lock (this) { headphones = _cachedHeadphones; device = _cachedDeviceId; }
            }
            if (pollLevel)
                level = SystemAudio.GetLevel();

            bool needStart = false;
            lock (this)
            {
                if (_soundTimer is null || epoch != _soundEpoch) return;
                if (pollDevice)
                {
                    _audioDevicePollAt = now;
                    _cachedHeadphones = headphones;
                    _cachedDeviceId = device;
                }
                if (pollLevel)
                    _audioLevelPollAt = now;
                headphones = _cachedHeadphones;
                device = _cachedDeviceId;

                if (headphones != Snapshot.SoundOnHeadphones) { Snapshot.SoundOnHeadphones = headphones; Publish(); }
                if (headphones)
                {
                    // Sound stays on the PC; the receiver goes back to its own level
                    if (_audio is not null) StopCapture(sendReset: true);
                    return;
                }
                var forceMain = Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_MAIN") == "1";
                // Without a cursor channel, capture only burns CPU and can stall DXGI — wait for it.
                if (!forceMain && _cursorConn is null)
                {
                    if (_audio is not null) StopCapture(sendReset: false);
                    if (Snapshot.SoundOnReceiver) { Snapshot.SoundOnReceiver = false; Publish(); }
                    return;
                }
                // Phase 2 stuck (muted, waiting for loopback proof): roll back.
                // Phase 1 (waiting for signal before mute) must NOT set unsupported — pace may not
                // have primed yet; marking unsupported left PC+RX both playing for the whole session.
                if (_mutePhase == 2 && Environment.TickCount64 - _mutePhaseAt > 2500)
                {
                    Console.WriteLine("[audio] local mute verify timed out; restoring PC speakers");
                    StopLocalMute();
                    _localMuteUnsupported = true;
                    RequestVolumeResync(); // do not send the pre-unmute Mute=true reading to RX
                }
                else if (_mutePhase == 1 && Environment.TickCount64 - _mutePhaseAt > 8000)
                {
                    // Still silent after a long wait — give up this attempt; SoundTick will retry.
                    Console.WriteLine("[audio] local mute: no signal yet; will retry");
                    _mutePhase = 0;
                }
                if (_audio is null || device != _soundDevice)
                {
                    StopCapture(sendReset: false);
                    if (_soundTimer is null || epoch != _soundEpoch) return;
                    _soundDevice = device;
                    needStart = true;
                }
                else if (!_localMuteUnsupported && !_localHandoffMute && _mutePhase == 0 && _audio is not null)
                {
                    // Retry handoff mute after a quiet/deferred attempt (Mac mutedWhenTapped).
                    BeginLocalMute();
                }
            }

            // WASAPI open/join outside the session lock so StopSound can bump epoch promptly.
            AudioLoopback? tap = null;
            if (needStart)
                tap = AudioLoopback.TryStart(OnAudio);

            lock (this)
            {
                if (needStart)
                {
                    if (_soundTimer is null || epoch != _soundEpoch)
                    {
                        tap?.Dispose();
                        return;
                    }
                    _audio = tap;
                    if (tap is not null)
                    {
                        var gen = _audioGen;
                        // Device unplug only: intentional StopCapture bumps _audioGen so dispose Stopped is ignored.
                        tap.Stopped += () =>
                        {
                            if (gen != _audioGen || !ReferenceEquals(_audio, tap)) return;
                            _audio = null;
                            _soundDevice = null;
                        };
                        Console.WriteLine($"[audio] playing '{tap.DeviceName}' on the receiver ({tap.SampleRate} Hz, {tap.Channels} ch, paced)");
                        // Mac: Volume before audio so RX is not left at a prior muted follow level.
                        level ??= SystemAudio.GetLevel();
                        if (level is { } startLevel)
                            SendFollowVolume(startLevel);
                        BeginLocalMute();
                    }
                    Snapshot.SoundOnReceiver = tap is not null;
                    Publish();
                }
                if (_soundTimer is null || epoch != _soundEpoch) return;
                // After mute rollback, re-read — a stale Mute=true would silence the iMac while PC speakers play.
                if (Interlocked.Exchange(ref _volumeResync, 0) != 0)
                    level = SystemAudio.GetLevel();
                // Receiver follows the user's volume/mute — never the temporary handoff mute on the endpoint.
                if (level is { } raw)
                    SendFollowVolume(raw);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("[audio] " + ex.Message);
        }
        finally
        {
            Interlocked.Exchange(ref _soundTickBusy, 0);
        }
    }

    private void OnAudio(int rate, int channels, short[] samples)
    {
        if (!Sound || Snapshot.Phase != SessionPhase.Streaming) return;
        var peak = 0;
        for (var i = 0; i < samples.Length; i++)
        {
            var a = samples[i] < 0 ? -samples[i] : samples[i];
            if (a > peak) peak = a;
        }
        TickLocalMute(peak);

        var w = new ByteWriter(6 + samples.Length * 2);
        w.U32((uint)rate);
        w.U8((byte)channels);
        w.U8(0);
        var bytes = new byte[samples.Length * 2];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        w.Bytes(bytes);
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_NOAUDIO") != "1")
            SendAudioMessage(new Message(MessageType.Audio, 0, w.ToArray()));
        _audioPackets++;
        var t = Environment.TickCount64;
        if (t - _audioReportAt > 5000)
        {
            _audioReportAt = t;
            Console.WriteLine($"[audio] {_audioPackets} packets sent localMute={_localHandoffMute}");
        }
    }

    /// <summary>
    /// Mac <c>muteWhenTapped</c>. Wait for real signal → mute speakers → require loopback to still
    /// carry signal; otherwise roll back (WASAPI often zeros capture when the endpoint is muted).
    /// Residual PCM right after mute must not count as success — that left RX silent after ~0.5 s.
    /// </summary>
    private void BeginLocalMute()
    {
        if (_localMuteUnsupported || _localHandoffMute || _mutePhase != 0) return;
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_LOCAL_MUTE") == "0") return;
        // Phase 1 starts after a short defer so endpoint mute does not hitch DXGI at the same
        // instant WASAPI starts (sound toggle → frozen picture).
        _mutePhase = 1;
        _muteWaitLeft = 150; // ~0.5 s defer + ~1 s seek for signal @ 10 ms
        _muteSettleLeft = 50; // reuse as defer counter while peak check is skipped
        _muteGoodPackets = 0;
        _mutePhaseAt = Environment.TickCount64;
    }

    private void TickLocalMute(int peak)
    {
        if (_mutePhase == 1)
        {
            if (_muteSettleLeft > 0)
            {
                _muteSettleLeft--;
                return; // defer mute while capture/encode settle after tap start
            }
            if (peak >= 200)
            {
                var prev = SystemAudio.TrySetMute(true);
                if (prev is null) { _mutePhase = 0; return; }
                _logicalMuted = prev.Value;
                _localHandoffMute = true;
                // Process loopback survives endpoint mute (Mac mutedWhenTapped) — no verify needed.
                if (_audio is { EndpointMuteSafe: true })
                {
                    _mutePhase = 0;
                    Console.WriteLine("[audio] PC speakers muted (handoff); process-loopback mute-safe");
                    return;
                }
                _mutePhase = 2;
                _muteSettleLeft = 30; // ~300 ms: ignore leftover samples after mute
                _muteWaitLeft = 80;   // ~800 ms of real checks after settle
                _muteGoodPackets = 0;
                _mutePhaseAt = Environment.TickCount64;
                Console.WriteLine("[audio] PC speakers muted (handoff); verifying loopback");
                return;
            }
            // Keep waiting for audible signal; wall-clock in SoundTick aborts phase 1 if endless.
            if (_muteWaitLeft > 0) _muteWaitLeft--;
            return;
        }
        if (_mutePhase == 2)
        {
            if (_muteSettleLeft > 0)
            {
                _muteSettleLeft--;
                return;
            }
            if (peak >= 64) _muteGoodPackets++;
            if (--_muteWaitLeft > 0) return;
            // Need sustained signal after settle — a single residual peak is not enough.
            if (_muteGoodPackets >= 10)
            {
                _mutePhase = 0;
                Console.WriteLine($"[audio] local mute OK — loopback still has audio ({_muteGoodPackets} pkts)");
            }
            else
            {
                StopLocalMute();
                _localMuteUnsupported = true;
                RequestVolumeResync();
                Console.WriteLine($"[audio] local mute killed loopback (good={_muteGoodPackets}); PC speakers stay on");
            }
        }
    }

    private void StopLocalMute()
    {
        if (_localHandoffMute)
            SystemAudio.TrySetMute(_logicalMuted);
        _localHandoffMute = false;
        _mutePhase = 0;
        _muteWaitLeft = 0;
        _muteSettleLeft = 0;
        _muteGoodPackets = 0;
    }

    /// <summary>SoundTick must re-read GetLevel after unmuting; otherwise RX keeps a Mute=true follow.</summary>
    private void RequestVolumeResync()
    {
        _sentLevel = null;
        Interlocked.Exchange(ref _volumeResync, 1);
    }

    /// <summary>Mac <c>sendOutputLevel</c>: RX hardware volume follows the PC (AudioQueue is full gain).</summary>
    private void SendFollowVolume(SystemAudio.Level raw)
    {
        var follow = new SystemAudio.Level(raw.Volume, _localHandoffMute ? _logicalMuted : raw.Muted);
        if (_sentLevel is { } sent && Math.Abs(sent.Volume - follow.Volume) <= 0.004f && sent.Muted == follow.Muted)
            return;
        var w = new ByteWriter(5);
        w.F32(follow.Volume);
        w.U8(follow.Muted ? (byte)1 : (byte)0);
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_NOVOL") != "1")
        {
            SendAudioMessage(new Message(MessageType.Volume, 0, w.ToArray()));
            Console.WriteLine($"[audio] volume={follow.Volume:0.00} mute={follow.Muted} handoff={_localHandoffMute}");
        }
        _sentLevel = follow;
    }

    /// <summary>
    /// Mac: audio/volume on the cursor channel so they never wait behind tile/video frames.
    /// Do not fall back onto the main link: continuous Audio there starved Tile/Video (frozen
    /// picture, missing cursor). AFTERSCREEN_SOUND_MAIN=1 forces main for soak tests only.
    /// </summary>
    private void SendAudioMessage(Message m)
    {
        var forceMain = Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND_MAIN") == "1";
        if (forceMain)
        {
            try { _conn?.Send(m); } catch { /* ignore */ }
            return;
        }
        try { _cursorConn?.Send(m); } catch { /* ignore */ }
    }

    private void StopCapture(bool sendReset)
    {
        StopLocalMute();
        var tap = _audio;
        _audio = null;
        _soundDevice = null;
        _audioGen++;
        tap?.Dispose();
        if (tap is not null && sendReset)
        {
            SendAudioMessage(new Message(MessageType.Volume, 0, Array.Empty<byte>())); // empty: receiver returns to its own level
            _sentLevel = null;
        }
        Snapshot.SoundOnReceiver = false;
    }

    private void StopSound()
    {
        Timer? t;
        lock (this)
        {
            _soundEpoch++;
            t = _soundTimer;
            _soundTimer = null;
        }
        t?.Dispose();
        // Timer.Dispose does not wait for an in-flight callback — spin until it drops the busy gate.
        var spin = Environment.TickCount64 + 2000;
        while (Volatile.Read(ref _soundTickBusy) != 0 && Environment.TickCount64 < spin)
            Thread.Sleep(1);
        lock (this)
            StopCapture(sendReset: true);
        Publish();
    }
}
