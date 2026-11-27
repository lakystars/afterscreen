using System.Runtime.InteropServices;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Encode;
using Afterscreen.Transport;

namespace Afterscreen.Sender.Session;

public enum SessionPhase
{
    Idle,
    Connecting,
    Pairing,
    Probing,
    Streaming,
    Ended,
}

public sealed class SenderSnapshot
{
    public SessionPhase Phase { get; set; } = SessionPhase.Idle;
    public string State { get; set; } = "Idle";
    public Welcome? Peer { get; set; }
    public StreamConfig? Config { get; set; }
    public double? CapacityGbps { get; set; }
    public string? PairingName { get; set; }
    public int FramesSent { get; set; }
    /// <summary>Receiver Bye.relink — Program should open a fresh session.</summary>
    public bool WantRelink { get; set; }
    /// <summary>Latest once-a-second stats (also sent to the receiver); null before streaming.</summary>
    public SenderStats? Stats { get; set; }
    /// <summary>Wrong pairing codes so far in this session (the UI shakes the code boxes on a change).</summary>
    public int WrongCodes { get; set; }
    /// <summary>Video bitrate now / at the start (RateControl lowers it while the link queues); null without a video layer.</summary>
    public int? VideoBitrate { get; set; }
    public int? VideoStartBitrate { get; set; }
    /// <summary>RateControl has held the picture well under its start for a while (Mac qualityLowered): the UI says the network is busy.</summary>
    public bool QualityLowered { get; set; }
    /// <summary>The PC's sound is playing on the receiver / the output is headphones, so it stays on the PC (Mac soundOnReceiver / soundOnHeadphones).</summary>
    public bool SoundOnReceiver { get; set; }
    public bool SoundOnHeadphones { get; set; }
    /// <summary>Built-in panel brightness 0…1 while following (Mac <c>macBrightness</c>); null when unreadable.</summary>
    public double? MacBrightness { get; set; }
    /// <summary>What the receiver measures (Stats message, once a second); null until the first one.</summary>
    public ReceiverStats? Receiver { get; set; }
    /// <summary>The receiver's own settings; null from an older receiver.</summary>
    public ReceiverOptions? ReceiverOptions { get; set; }
    /// <summary>Quality test progress and results (Mac "Test"); null outside a test.</summary>
    public QualityTest.Report? Quality { get; set; }
    /// <summary>Active link kind while streaming (Mac <c>snapshot.link</c>).</summary>
    public LinkKind? Link { get; set; }
    /// <summary>Mac <c>missingLink</c>: preferred kind that was unavailable; null when on the chosen link.</summary>
    public LinkKind? MissingLink { get; set; }
    /// <summary>Mac <c>interface</c>: local NIC name for the active route.</summary>
    public string? Interface { get; set; }
}

/// <summary>LAN-only session: Hello → auth/pair → probe → config → stub frames.</summary>
public sealed partial class SenderSession : IDisposable
{
    public const int StreamWidth = 2880;
    public const int StreamHeight = 1620;

    private string _host;
    private readonly int _port;
    private readonly string _senderId;
    private readonly IPairingStore _store;
    private readonly byte[] _helloNonce = Pairing.Nonce();
    private LinkKind _linkKind;
    private readonly TaskCompletionSource _ended = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private Connection? _conn;
    private Connection? _cursorConn;
    private CursorTracker? _cursor;
    private Welcome? _pendingWelcome;
    private (byte[] Session, byte[] Key, Pairing.Transcript Transcript)? _pendingPair;
    private CancellationTokenSource? _streamCts;
    private CancellationTokenSource? _keepaliveCts;
    private uint _frameIndex;
    private int _probeFinished; // 0 → 1 once; ProbeResult vs timeout
    private volatile bool _wantKeyframe;
    private double? _loggedReceiverPanel; // AFTERSCREEN_BRIGHTNESS=1: last Stats.panelLevel we printed
    private TimeSpan _lastCpuTime;
    private static readonly bool IdrDiagnostics =
        string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal);
    private long _lastCpuSampleMs;
    private Capture.DxgiCapture? _dxgi;
    private Encode.IVideoEncoder? _videoRef;
    private Encode.ITileEncoder? _tilesRef;
    // Tiles sent per format since the last stats line (diagnostic): BC7 / BC1 / video-masked.
    private int _fmtBc7, _fmtBc1, _fmtVideo, _clsStill, _clsMoving;
    private double _probeMsSum;
    private int _probeN;
    private Timer? _routeWatch;
    private int _inactiveChecks;
    private string? _routeInterface;

    public SenderSnapshot Snapshot { get; } = new();
    public event Action<SenderSnapshot>? OnUpdate;
    public Func<string>? CodeProvider { get; set; }
    public bool EnableCapture { get; set; } = true;
    /// <summary>Discovery device id / name for Hello.Paired (Mac target.deviceID).</summary>
    public string? PeerDeviceId { get; set; }
    public string? PeerName { get; set; }
    /// <summary>Mac <c>disowned</c>: next Hello asks the receiver to pair with a code again.</summary>
    private static readonly HashSet<string> Disowned = new(StringComparer.OrdinalIgnoreCase);

    public SenderSession(string host, int port, string senderId, IPairingStore store, LinkKind linkKind = LinkKind.wifi)
    {
        _host = host;
        _port = port;
        _senderId = senderId;
        _store = store;
        _linkKind = linkKind;
    }

    public async Task RunAsync(CancellationToken ct = default)
    {
        Set(SessionPhase.Connecting, "Connecting");
        using var reg = ct.Register(Dispose);

        _conn = await Connection.ConnectAsync(_host, _port, TimeSpan.FromSeconds(12), ct).ConfigureAwait(false);
        _conn.OnMessage = m =>
        {
            try { Handle(m); }
            catch (Exception ex) { End("handle: " + ex.Message); }
        };
        _conn.OnClose = ConnectionClosed;
        _conn.Start();

        // Mac: Paired only when we keep a key for this receiver's id (not "any pairing exists").
        var pairedHint = PeerDeviceId is { Length: > 0 } && _store.Key(PeerDeviceId) is not null;
        var repair = PeerDeviceId is { Length: > 0 } && Disowned.Contains(PeerDeviceId);
        var hello = new Hello
        {
            ProtocolVersion = AfterscreenProtocol.Version,
            Name = Environment.MachineName,
            Model = "Windows-Sender",
            OsVersion = RuntimeInformation.OSDescription,
            SenderID = _senderId,
            Nonce = _helloNonce,
            Paired = pairedHint,
            Repair = repair ? true : null,
            ReadsOptions = true,
        };
        _conn.Send(JsonWire.Message(MessageType.Hello, hello));

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        await _ended.Task.WaitAsync(linked.Token).ConfigureAwait(false);
    }

    private void Handle(Message msg)
    {
        if (Snapshot.Phase == SessionPhase.Ended)
            return;

        switch (msg.Type)
        {
            case MessageType.Welcome:
            {
                var welcome = JsonWire.Decode<Welcome>(msg.Payload);
                Snapshot.Peer = welcome;
                if (welcome.ProtocolVersion != AfterscreenProtocol.Version)
                {
                    End($"protocol {welcome.ProtocolVersion}");
                    return;
                }
                if (welcome.Auth is null)
                {
                    Admitted(welcome);
                    return;
                }
                _pendingWelcome = welcome;
                if (welcome.ReceiverID is null)
                {
                    End("no receiverID");
                    return;
                }
                if (welcome.Auth.Mode == AuthMode.paired)
                {
                    var key = _store.Key(welcome.ReceiverID);
                    if (key is null)
                    {
                        // Rotated receiver id or stale Hello.Paired: forget name-matched keys, ask to re-pair.
                        foreach (var (id, name) in _store.Pairs.ToList())
                            if (name == welcome.Name || id == welcome.ReceiverID)
                                _store.Remove(id);
                        Disowned.Add(welcome.ReceiverID);
                        Snapshot.WantRelink = true;
                        End($"{Environment.MachineName} lost its pairing with {welcome.Name}; connect again to pair");
                        return;
                    }
                    var t = Transcript(welcome);
                    _conn!.Send(JsonWire.Message(MessageType.Auth, new AuthProof
                    {
                        Mac = Pairing.Proof(key, Pairing.Role.Sender, t),
                    }));
                    Set(SessionPhase.Pairing, "Checking pairing");
                }
                else
                {
                    Set(SessionPhase.Pairing, "Waiting for code");
                    Snapshot.PairingName = welcome.Name;
                    Publish();
                    // Receiver idle-timeout is ~4s; keep the socket alive until the code arrives.
                    StartKeepalive();
                    // Don't block the reader thread while waiting for the user.
                    _ = Task.Run(() =>
                    {
                        try
                        {
                            var code = CodeProvider?.Invoke()
                                       ?? throw new InvalidOperationException("pairing code required");
                            SubmitPairingCode(code);
                        }
                        catch (Exception ex)
                        {
                            End("pairing: " + ex.Message);
                        }
                    });
                }
                return;
            }
            case MessageType.AuthOK:
            {
                if (_pendingWelcome is null || _pendingWelcome.ReceiverID is null)
                    return;
                var key = _store.Key(_pendingWelcome.ReceiverID);
                var proof = JsonWire.Decode<AuthProof>(msg.Payload);
                var t = Transcript(_pendingWelcome);
                if (key is null || !Pairing.Matches(proof.Mac, Pairing.Proof(key, Pairing.Role.Receiver, t)))
                {
                    End("authOK mismatch");
                    return;
                }
                var w = _pendingWelcome;
                _pendingWelcome = null;
                Admitted(w);
                return;
            }
            case MessageType.Paired:
            {
                if (_pendingWelcome is null || _pendingPair is null || _pendingWelcome.ReceiverID is null)
                    return;
                var proof = JsonWire.Decode<AuthProof>(msg.Payload);
                if (!Pairing.Matches(proof.Mac, Pairing.PairedProof(_pendingPair.Value.Session, _pendingPair.Value.Transcript)))
                {
                    End("paired mismatch");
                    return;
                }
                _store.Save(_pendingPair.Value.Key, _pendingWelcome.ReceiverID, _pendingWelcome.Name);
                Disowned.Remove(_pendingWelcome.ReceiverID);
                var w = _pendingWelcome;
                _pendingWelcome = null;
                _pendingPair = null;
                Snapshot.PairingName = null;
                Admitted(w);
                return;
            }
            case MessageType.PairWrong:
                _pendingPair = null;                 // allow another code
                Snapshot.WrongCodes++;
                Set(SessionPhase.Pairing, "Wrong code — retry");
                return;
            case MessageType.ProbeResult:
            {
                var result = JsonWire.Decode<ProbeResult>(msg.Payload);
                Console.WriteLine($"[probe] result bytes={result.Bytes} s={result.Seconds:F3} gbps={result.Gbps:F2}");
                FinishProbe(result.Gbps);
                return;
            }
            case MessageType.Bye:
            {
                var bye = JsonWire.Decode<Bye>(msg.Payload);
                if (bye.Relink)
                    Snapshot.WantRelink = true;
                End(bye.Reason);
                return;
            }
            case MessageType.Stats:
                try
                {
                    Snapshot.Receiver = JsonWire.Decode<ReceiverStats>(msg.Payload);
                    // Dev: confirm the receiver applied Brightness (Stats.panelLevel once a second).
                    if (Environment.GetEnvironmentVariable("AFTERSCREEN_BRIGHTNESS") == "1"
                        && Snapshot.Receiver?.PanelLevel is { } pl
                        && (_loggedReceiverPanel is null || Math.Abs(_loggedReceiverPanel.Value - pl) >= 0.004))
                    {
                        _loggedReceiverPanel = pl;
                        Console.WriteLine($"[brightness] receiver panelLevel={pl:0.00}");
                    }
                }
                catch { /* a newer receiver's shape: keep the last good one */ }
                return;
            case MessageType.ReceiverOptions:
                // Unreadable, as from a newer receiver: no edits offered
                try { Snapshot.ReceiverOptions = JsonWire.Decode<ReceiverOptions>(msg.Payload); }
                catch (Exception ex) { Snapshot.ReceiverOptions = null; Console.WriteLine("[receiver] options unreadable: " + ex.Message); }
                Console.WriteLine($"[receiver] options editable={Snapshot.ReceiverOptions?.Editable} hud={Snapshot.ReceiverOptions?.Hud} screens={Snapshot.ReceiverOptions?.Screens.Count}");
                Publish();
                return;
            case MessageType.KeyRequest:
                // StreamLoop picks this up on the next video encode.
                _wantKeyframe = true;
                return;
        }
    }

    /// <summary>Mac <c>streamResolution</c>: auto | panel | reduced (PathPolicy).</summary>
    public string StreamResolution { get; set; } = "auto";

    /// <summary>Receiver 8-bit step smoothing; sent at the start of streaming and on change (Mac setDeband).</summary>
    public Deband Deband { get; set; } = Deband.Normal;

    public void SetDeband(Deband level)
    {
        Deband = level;
        SendDeband();
    }

    private void SendDeband()
    {
        if (_conn is { IsClosed: false } c)
            c.Send(new Message(MessageType.Deband, 0, new[] { (byte)Deband }));
    }

    /// <summary>Mac setReceiverOptions: a receiver settings edit, shown at once. Only where the receiver reported them editable.</summary>
    public void SetReceiverOptions(ReceiverOptionsChange change)
    {
        if (Snapshot.ReceiverOptions is not { Editable: true } options || _conn is not { IsClosed: false } c) return;
        c.Send(JsonWire.Message(MessageType.SetReceiverOptions, change));
        Snapshot.ReceiverOptions = options.Applying(change);
        Publish();
    }

    /// <summary>Mac flashBlocks: the receiver flashes changed / refined / video blocks (check aid).</summary>
    public bool FlashBlocks { get; set; }

    public void SubmitPairingCode(string code)
    {
        if (_pendingWelcome?.Auth is not { Mode: AuthMode.pair } challenge || challenge.PublicKey is null)
            return;
        if (_pendingPair is not null)
            return;

        var own = Pairing.NewKey();
        var t = Transcript(_pendingWelcome);
        t.SenderKey = own.PublicKey;
        t.ReceiverKey = challenge.PublicKey;
        var session = Pairing.SessionKey(own, challenge.PublicKey, t);
        var key = Pairing.PairingKey(session, code, t);
        _pendingPair = (session, key, t);
        _conn!.Send(JsonWire.Message(MessageType.Pair, new PairConfirm
        {
            PublicKey = own.PublicKey,
            Mac = Pairing.Confirm(session, code, t),
        }));
        Set(SessionPhase.Pairing, "Pairing");
    }

    private void StartKeepalive()
    {
        StopKeepalive();
        _keepaliveCts = new CancellationTokenSource();
        var ct = _keepaliveCts.Token;
        _ = Task.Run(async () =>
        {
            var payload = new byte[8]; // PingWire: u64 timestamp
            while (!ct.IsCancellationRequested &&
                   Snapshot.Phase is SessionPhase.Pairing or SessionPhase.Probing or SessionPhase.Streaming)
            {
                try
                {
                    BitConverter.TryWriteBytes(payload, (ulong)Environment.TickCount64);
                    _conn?.Send(new Message(MessageType.Ping, 0, payload));
                }
                catch { break; }
                try { await Task.Delay(1000, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }, ct);
    }

    private void StopKeepalive()
    {
        try { _keepaliveCts?.Cancel(); } catch { /* ignore */ }
        _keepaliveCts?.Dispose();
        _keepaliveCts = null;
    }

    private void Admitted(Welcome welcome)
    {
        // Keepalive through probe + first heavy encode frames (receiver idle timeout ~4s).
        StartKeepalive();
        // Cursor channel after Config — opening it during probe raced the receiver's
        // offerChannel/giveWay path ("송신기가 다시 연결했습니다") on fast reconnects.
        _probeFinished = 0;
        Set(SessionPhase.Probing, "Measuring link");
        // Mac 1.1.1 SenderSession.probe: 0.3s, backlog ≈ 100 ms of acked rate.
        // Must not run on the read/Handle thread — that blocked ProbeResult.
        _ = Task.Run(() =>
        {
            // 256 KiB chunks: 1 MiB writes + small SNDBUF previously stalled WriteLoop.
            var block = new byte[256 << 10];
            Random.Shared.NextBytes(block);
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var handed = 0L;
            try
            {
                while (sw.Elapsed < TimeSpan.FromSeconds(0.3) && Snapshot.Phase == SessionPhase.Probing
                       && _conn is { IsClosed: false } && _probeFinished == 0)
                {
                    var queued = _conn.QueuedBytes;
                    var elapsed = Math.Max(0.001, sw.Elapsed.TotalSeconds);
                    var acked = Math.Max(0L, handed - queued);
                    var target = ProbeQueueBytes(acked, elapsed);
                    if (queued < target)
                    {
                        var n = (int)Math.Min(block.Length, Math.Max(64 << 10, target / 4));
                        var payload = n == block.Length ? block : block.AsSpan(0, n).ToArray();
                        _conn.Send(new Message(MessageType.Probe, 0, payload));
                        handed += n;
                    }
                    else
                        Thread.Sleep(2);
                }
                if (_probeFinished == 0)
                {
                    _conn?.Send(new Message(MessageType.Probe, ProbeFlags.End, Array.Empty<byte>()));
                    Console.WriteLine($"[probe] end sent handed={handed} queued={_conn?.QueuedBytes ?? -1}");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("[probe] send failed: " + ex.Message);
            }

            // Receiver sometimes never answers (takeover/probe reset). Don't sit forever.
            try { Thread.Sleep(2000); } catch { /* ignore */ }
            if (_probeFinished == 0 && Snapshot.Phase == SessionPhase.Probing)
            {
                var elapsed = Math.Max(0.001, sw.Elapsed.TotalSeconds);
                var gbps = handed > 0 ? handed * 8.0 / elapsed / 1e9 : 1.0;
                Console.WriteLine($"[probe] timeout — starting at ~{gbps:F2} Gbps (handed={handed})");
                FinishProbe(gbps);
            }
        });
    }

    /// <summary>Mac SenderSession.probeQueue — 100 ms of acknowledged rate, clamped.</summary>
    private static long ProbeQueueBytes(long acked, double elapsedSec)
    {
        var rate = elapsedSec > 0 ? acked / elapsedSec : 0;
        return (long)Math.Clamp(rate * 0.1, 256 << 10, 12 << 20);
    }

    private void FinishProbe(double gbps)
    {
        if (System.Threading.Interlocked.CompareExchange(ref _probeFinished, 1, 0) != 0)
            return;
        if (Snapshot.Phase is not SessionPhase.Probing)
            return;
        Snapshot.CapacityGbps = gbps;
        var welcome = Snapshot.Peer;
        if (welcome is null)
        {
            End("probe: no peer");
            return;
        }
        // MF prove can take seconds — never block the read thread on it.
        _ = Task.Run(() =>
        {
            try { BeginStreaming(welcome, gbps); }
            catch (Exception ex) { End("encode: " + ex.Message); }
        });
    }

    private async Task OpenCursorChannelAsync(uint token)
    {
        if (token == 0)
        {
            if (Sound) StartSound();
            return;
        }
        try
        {
            var c = await Connection.ConnectAsync(_host, _port, TimeSpan.FromSeconds(3)).ConfigureAwait(false);
            // First message on this socket must be cursorChannel (not Hello).
            c.Send(new Message(MessageType.CursorChannel, 0, ChannelWire.Encode(token)));
            c.OnClose = _ => { if (ReferenceEquals(_cursorConn, c)) _cursorConn = null; };
            c.Start();
            _cursorConn = c;
            Console.WriteLine("[cursor] channel open");
            // Mac: sound waits for the cursor channel so audio never queues behind frames.
            if (Sound) StartSound();
        }
        catch (Exception ex)
        {
            // Audio stays off the main link (would starve video). Cursor/video use main.
            Console.WriteLine("[cursor] channel failed: " + ex.Message);
            _cursorConn = null;
            if (Sound) StartSound();
        }
    }

    private void SendCursor(Message message)
    {
        var c = _cursorConn ?? _conn;
        try { c?.Send(message); } catch { /* ignore */ }
    }

    private void BeginStreaming(Welcome welcome, double gbps)
    {
        if (TestMode)
        {
            _streamCts = new CancellationTokenSource();
            Set(SessionPhase.Streaming, "Testing");
            _ = Task.Run(() =>
            {
                try { RunQualityTest(welcome, gbps, _streamCts.Token); }
                catch (Exception ex) { End("quality test: " + ex.Message); }
            });
            return;
        }
        Console.WriteLine($"[encode] creating pipeline gbps={gbps:F2}…");
        EncodePipeline pipeline;
        try
        {
            pipeline = EncodeServices.Create(welcome, _linkKind, gbps, streamResolution: StreamResolution);
        }
        catch (Exception ex)
        {
            End("encode: " + ex.Message);
            return;
        }

        if (Snapshot.Phase is SessionPhase.Ended)
        {
            pipeline.Dispose();
            return;
        }

        var config = pipeline.Config;
        Snapshot.Config = config;
        Snapshot.Link = _linkKind;
        RefreshRouteInterface(_host, _linkKind);
        _conn!.Send(JsonWire.Message(MessageType.Config, config));
        Set(SessionPhase.Streaming, "Streaming (" + pipeline.Summary + ")");
        SendDeband();
        StartBrightnessFollow();
        StartRouteWatch();
        _ = OpenCursorChannelAsync(welcome.ChannelToken);
        // Sound starts once the cursor channel is up (or after that attempt fails).

        _streamCts = new CancellationTokenSource();
        _ = Task.Run(() =>
        {
            if (MacTilesEnabled)
                StreamLoopMac(pipeline, _streamCts.Token);
            else
                StreamLoop(pipeline, _streamCts.Token);
        }, _streamCts.Token);
    }

    private void StreamLoop(EncodePipeline pipeline, CancellationToken ct)
    {
        using (pipeline)
        using (var timer = HighResTimer.Begin())
        {
            var config = pipeline.Config;
            var geometry = new TileGeometry(config.StreamPixels.Width, config.StreamPixels.Height);
            var intervalMs = 1000.0 / Math.Max(1, config.FrameRate);
            var tiles = pipeline.Tiles;
            var video = pipeline.Video;
            _videoRef = video;
            _tilesRef = tiles;
            var hybrid = config.Path == StreamPath.hybrid && video is not null;
            // Mac TileEncoder motion vs still — enter a bit higher so typing stays BC7/BC1.
            const double videoEnterShare = 0.08;
            const double videoExitShare = 0.03;
            // A "scene cut" turns EVERY tile into video, including tiles that did not change. At 0.30 two large
            // windows were enough: scrolling one smeared the other until it settled. Mac only masks the tiles that
            // change, so the whole-frame rule is kept only for (almost) full-screen changes. AFTERSCREEN_SCENECUT=0.3
            // restores the old threshold.
            var sceneCutShare = double.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_SCENECUT"),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var envCut)
                && envCut is > 0.05 and <= 1.0 ? envCut : 0.90;
            const int videoHoldFrames = 8;
            // Mac settles BC7 on Metal (~ms). GPU D3D path can settle; CPU must not.
            const int settleCleanFrames = 2;
            // Mac Metal refine is cheap; Iris D3D EncodeMarks(4–8) was 40–90ms and
            // collapsed sentFPS. Clear sticky without BC7 for now — still areas return
            // via the tile path after leaving video (same as earlier hybrid FPS path).
            const int settleLimit = 0;
            var videoHold = 0;
            var onVideo = false;
            var videoParamsSent = false;
            var wantVideoKeyframe = true;
            var keyframeForceSent = false; // RequestKeyframe once per wait — spamming MF crashes/IDR-floods
            var idrWaitFrames = 0; // re-poke keyframe if SW GOP stalls
            var videoNullStreak = 0; // Mac fallBackToBC1 when the layer stops producing
            var droppedSinceSend = 0; // Mac: after gate drops, next video needs a keyframe
            // Mac onVideo[]: tiles that entered the video layer stay masked until BC7 settle.
            var stickyVideo = new bool[geometry.TileCount];
            var stickyClean = new int[geometry.TileCount];
            // Mac TileEncoder.refine(): tiles that stayed still for settleDelay are re-sent as BC7 while
            // the link has room (also when no new frame arrives — a static desktop yields no frames).
            // Without it a tile that left the video layer stays masked on the receiver showing the last,
            // lossy video picture until it changes again. AFTERSCREEN_SETTLE=0 disables.
            var directBc7 = !string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_DIRECT_BC7"), "0", StringComparison.Ordinal);
            // Mac TileEncoder: a changed tile is "moving" (cheap BC1, settles later) when it changed again within
            // motionWindow (50 ms) or while it is still lossy and has not been still for settleDelay (100 ms);
            // a tile that changes after being still goes out as BC7 at once.
            const long motionWindowMs = 50;
            // Mac PathPolicy budgets from the measured link capacity (tiles per frame): settleTiles = what the link
            // carries in one frame interval (BC7 for tiles that change after being still, and the settle size);
            // bc7MotionTiles = half of that, how many MOVING tiles may stay BC7 instead of dropping to BC1.
            var linkGbps = Snapshot.CapacityGbps ?? 0;
            var tileBytes = geometry.TilePixels * geometry.TilePixels;   // BC7: 1 byte per pixel
            var cfgFps = Math.Max(1.0, config.FrameRate);
            var settleBase = Math.Max(16, (int)(linkGbps * 1e9 / 8 / cfgFps / tileBytes));
            var bc7MotionLimit = (int)(linkGbps * 0.5e9 / 8 / cfgFps / tileBytes);
            byte[]? tileClass = null;             // per frame: 1 = changed after being still, 2 = moving, 0 = unchanged
            var stillCount = 0;
            var movingCount = 0;
            var settleEnabled = !string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_SETTLE"), "0", StringComparison.Ordinal);
            const long settleDelayMs = 100;       // Mac TileEncoder.settleDelay
            const int settleBudgetBusy = 64;      // tiles per refine while frames are flowing (a call is ~6 ms)
            const int settleBudgetIdle = 256;     // tiles per refine when nothing else is pending (Mac: no limit)
            const long settleBusyGapMs = 33;      // min gap between refines while frames are flowing
            var lastDirtyMs = new long[geometry.TileCount];
            byte[]? lastBgra = null;
            var lastBgraW = 0;
            var lastBgraH = 0;
            var lastRefineMs = 0L;
            // Mac FrameCounters → SenderStats (1 Hz HUD).
            var statsAt = Environment.TickCount64;
            var encodeMsSum = 0.0;
            var encodedFrames = 0;
            var dirtyTilesSum = 0;
            var dirtySamples = 0;
            var rawTileBytes = 0L;
            var wireTileBytes = 0L;
            var sentFrames = 0;
            var captureFrames = 0;
            var droppedFrames = 0;
            _wantKeyframe = false;
            DxgiCapture? capture = null;
            if (EnableCapture)
            {
                try
                {
                    capture = new DxgiCapture(config.StreamPixels.Width, config.StreamPixels.Height);
                    capture.Start();
                    _dxgi = capture;
                    _cursor?.Dispose();
                    _cursor = new CursorTracker(new System.Drawing.Rectangle(
                        capture.MonitorLeft, capture.MonitorTop, capture.MonitorWidth, capture.MonitorHeight));
                    _cursor.OnPosition += (x, y, visible) =>
                        SendCursor(new Message(MessageType.CursorPos, 0, CursorWire.Pos(x, y, visible)));
                    _cursor.OnImage += (png, w, h, hotX, hotY) =>
                    {
                        var sx = (double)config.StreamPixels.Width / Math.Max(1, capture.MonitorWidth);
                        var sy = (double)config.StreamPixels.Height / Math.Max(1, capture.MonitorHeight);
                        SendCursor(new Message(MessageType.CursorImage, 0, CursorWire.Image(
                            (int)Math.Round(w * sx), (int)Math.Round(h * sy),
                            (int)Math.Round(hotX * sx), (int)Math.Round(hotY * sy), png)));
                    };
                    _cursor.Start();
                }
                catch (Exception ex)
                {
                    Snapshot.State = $"Streaming (no capture: {ex.Message})";
                    Publish();
                }
            }

            // Mac FrameGate + FrameStreamer.pump: offer captures, take when !busy && paced.
            var gate = new FrameGate<Capture.CapturedFrame>(intervalMs - 2);
            while (!ct.IsCancellationRequested && Snapshot.Phase == SessionPhase.Streaming)
            {
                try
                {
                    if (_conn is null || _conn.IsClosed)
                    {
                        End("closed: stream peer");
                        break;
                    }

                    var now = Environment.TickCount64;
                    // Mac inFlight < 2; also bound message pairs so VideoFrame+TileFrame
                    // cannot hide SNDBUF backlog after QueuedFrames looks idle.
                    var qf = _conn?.QueuedFrames ?? 0;
                    // Normal queue only — priority Audio/Cursor must not freeze capture (sound-on → stuck picture).
                    var qm = _conn?.QueuedNormalMessages ?? 0;
                    // Mac inFlight < 2 (wire) + outbox waitsForVideo. Do not Take a new
                    // capture while QSV still holds the prior input — that returned null
                    // and dropped the gate frame (sentFPS 4–8 with enc still cheap).
                    var videoBusy = hybrid && onVideo && video is { InputInFlight: true };
                    var busy = qf >= 2 || qm >= 4 || videoBusy;
                    // Full TryCapture does monitor readback+CPU scale. Doing that every
                    // spin (then Sleep) starved Take: cap≈40 with sent≈7. Mac feeds the
                    // gate off a capture callback; we only readback when the gate needs it.
                    if (capture is not null)
                    {
                        var needCapture = gate.Pending is null || (!busy && gate.DelayMs(now) <= 4);
                        if (needCapture)
                        {
                            if (capture.TryCapture(out var offered, 1) && offered is not null)
                            {
                                captureFrames++;
                                // Mac CapturedFrame.merge: a frame replacing an unsent one carries
                                // both frames' dirty regions (the dropped one was never encoded).
                                var dropped = gate.Pending;
                                if (dropped is not null)
                                    offered.Dirty = Capture.CapturedFrame.Merge(dropped.Dirty, offered.Dirty);
                                if (gate.Offer(offered) && gate.DelayMs(now) == 0)
                                {
                                    droppedSinceSend++;
                                    droppedFrames++;
                                }
                            }
                        }
                        else
                        {
                            while (capture.TryPump(0)) { /* drain DXGI without scale */ }
                        }
                    }

                    var frame = gate.Take(now, busy);
                    if (frame is null)
                    {
                        if (videoBusy && video is not null)
                        {
                            var late = video.PollOutput(20);
                            if (late is not null)
                            {
                                videoNullStreak = 0;
                                if (late.Keyframe && late.ParameterSets is { Length: > 0 })
                                {
                                    _conn?.Send(new Message(MessageType.VideoParams, 0,
                                        VideoWire.Params(config.Video?.Codec ?? VideoCodec.h264, late.ParameterSets)));
                                    videoParamsSent = true;
                                }
                                if (wantVideoKeyframe && late.Keyframe && videoParamsSent)
                                {
                                    wantVideoKeyframe = false;
                                    keyframeForceSent = false;
                                    idrWaitFrames = 0;
                                }
                                if (videoParamsSent)
                                {
                                    _conn?.Send(new Message(MessageType.VideoFrame, 0,
                                        VideoWire.Frame(late.Keyframe, late.Avcc)));
                                    _conn?.Send(new Message(MessageType.TileFrame, 0,
                                        TileFrameWire.VideoPresent(_frameIndex++, geometry)));
                                    Snapshot.FramesSent++;
                                    sentFrames++;
                                    Snapshot.State = $"Streaming (video poll {(late.Keyframe ? "IDR" : "P")})";
                                }
                            }
                        }
                        // Wake near emit time; long sleeps + capture scale missed the gate.
                        var delay = gate.DelayMs(Environment.TickCount64);
                        var wait = gate.Pending is not null && !busy
                            ? (int)Math.Min(Math.Max(1, delay), 4)
                            : (int)Math.Min(Math.Max(1, delay), 8);
                        if (busy && !videoBusy)
                            Snapshot.State = $"Streaming (backpressure qf={qf} qm={qm})";
                        else if (videoBusy)
                            Snapshot.State = "Streaming (video inFlight)";
                        // Refine only while the connection has room: its BC7 frames are not droppable.
                        if (settleEnabled && lastBgra is not null && qf < 2 && qm < 4)
                        {
                            var nowMs = Environment.TickCount64;
                            var idle = gate.Pending is null && !busy;
                            if (nowMs - lastRefineMs >= (idle ? 16 : settleBusyGapMs))
                            {
                                byte[]? settleMarks = null;
                                var settleCount = 0;
                                var budget = idle ? settleBudgetIdle : settleBudgetBusy;
                                var lossyBc1 = tiles.LossyBc1;
                                for (var i = 0; i < stickyVideo.Length && settleCount < budget; i++)
                                {
                                    // Video-masked tiles and tiles shown as lossy BC1 both settle to BC7.
                                    var lossy = stickyVideo[i] || (i < lossyBc1.Length && lossyBc1[i]);
                                    if (!lossy || nowMs - lastDirtyMs[i] < settleDelayMs) continue;
                                    settleMarks ??= new byte[stickyVideo.Length];
                                    settleMarks[i] = (byte)(TileFormat.Bc7 + 1);
                                    settleCount++;
                                }
                                if (settleMarks is not null)
                                {
                                    var refineT0 = System.Diagnostics.Stopwatch.GetTimestamp();
                                    var refined = tiles.EncodeMarks(lastBgra, lastBgraW, lastBgraH, _frameIndex++, settleMarks);
                                    var refineMs = System.Diagnostics.Stopwatch.GetElapsedTime(refineT0).TotalMilliseconds;
                                    if (refined is not null)
                                    {
                                        _conn?.Send(new Message(MessageType.TileFrame, 0, refined.Payload));
                                        wireTileBytes += refined.Payload.Length;
                                        rawTileBytes += refined.Payload.Length;
                                        if (IdrDiagnostics)
                                            Console.WriteLine($"[settle] bc7 tiles={settleCount} bytes={refined.Payload.Length} idle={idle} enc={refineMs:0.0}ms t={Environment.TickCount64 % 1000000}");
                                    }
                                    for (var i = 0; i < settleMarks.Length; i++)
                                    {
                                        if (settleMarks[i] == 0) continue;
                                        stickyVideo[i] = false;
                                        stickyClean[i] = 0;
                                    }
                                }
                                lastRefineMs = nowMs;
                            }
                        }
                        timer.Sleep(wait);
                        FlushSenderStats(ref statsAt, ref encodeMsSum, ref encodedFrames, ref dirtyTilesSum, ref dirtySamples,
                            ref rawTileBytes, ref wireTileBytes, ref sentFrames, ref captureFrames, ref droppedFrames,
                            stickyVideo, config);
                        continue;
                    }

                    {
                        var frameIndex = _frameIndex++;
                        var encSw = System.Diagnostics.Stopwatch.StartNew();
                        var probeT0 = System.Diagnostics.Stopwatch.GetTimestamp();
                        var probe = tiles.Probe(frame.Bgra, frame.Width, frame.Height, frame.Dirty);
                        lastBgra = frame.Bgra;
                        lastBgraW = frame.Width;
                        lastBgraH = frame.Height;
                        tileClass = null;
                        stillCount = 0;
                        movingCount = 0;
                        if (probe.Marks is { } probeMarks)
                        {
                            var tNow = Environment.TickCount64;
                            var lossyBc1Now = tiles.LossyBc1;
                            if (directBc7 && !probe.Keyframe)
                                tileClass = new byte[probeMarks.Length];
                            for (var i = 0; i < probeMarks.Length && i < lastDirtyMs.Length; i++)
                            {
                                if (probeMarks[i] == 0) continue;
                                if (tileClass is not null)
                                {
                                    // Decide before lastDirtyMs is refreshed: it holds the previous change. A tile
                                    // that is lossy (BC1 or video) counts as moving until still for settleDelay.
                                    var since = tNow - lastDirtyMs[i];
                                    var lossyNow = stickyVideo[i] || (i < lossyBc1Now.Length && lossyBc1Now[i]);
                                    var moving = since < motionWindowMs || (lossyNow && since < settleDelayMs);
                                    tileClass[i] = (byte)(moving ? 2 : 1);
                                    if (moving) movingCount++; else stillCount++;
                                    if (moving) _clsMoving++; else _clsStill++;
                                }
                                lastDirtyMs[i] = tNow;
                            }
                        }
                        _probeMsSum += System.Diagnostics.Stopwatch.GetElapsedTime(probeT0).TotalMilliseconds;
                        _probeN++;
                        dirtyTilesSum += probe.DirtyTiles;
                        dirtySamples++;
                        if (hybrid)
                        {
                            // Mac TileEncoder: motion/lossy → video; settle → BC7.
                            // Dirty share gates the layer (not Probe.Keyframe — that only
                            // means "no previous frame" / periodic full refresh).
                            if (probe.DirtyShare >= videoEnterShare)
                            {
                                // Scene cut / heavy scroll: whole frame → video (avoids tile crawl).
                                // Light dirty: only those tiles go sticky — keep still UI on BC7.
                                if (probe.DirtyShare >= sceneCutShare)
                                {
                                    for (var i = 0; i < stickyVideo.Length; i++)
                                    {
                                        stickyVideo[i] = true;
                                        stickyClean[i] = 0;
                                    }
                                }
                                else if (probe.Marks is { } dm)
                                {
                                    for (var i = 0; i < stickyVideo.Length && i < dm.Length; i++)
                                    {
                                        if (dm[i] == 0) continue;
                                        stickyVideo[i] = true;
                                        stickyClean[i] = 0;
                                    }
                                }
                                // Mac: IDR on layer start / request — not every brief re-enter.
                                if (!onVideo)
                                {
                                    wantVideoKeyframe = true;
                                    keyframeForceSent = false;
                                }
                                onVideo = true;
                                videoHold = videoHoldFrames;
                            }
                            else if (onVideo)
                            {
                                if (probe.DirtyShare <= videoExitShare)
                                    videoHold = Math.Max(0, videoHold - 1);
                                else
                                    videoHold = videoHoldFrames;
                                // Stay on video while any tile is still masked (Mac lossyTiles).
                                if (videoHold == 0 && !stickyVideo.AsSpan().Contains(true))
                                    onVideo = false;
                            }
                        }
                        // Mac FrameStreamer: video.encode only while lossyTiles > 0.
                        // Always-on QSV for still UI pushed enc to 40–90ms after warm-up.
                        var useVideo = hybrid && video is not null && onVideo;
                        // Mac: keyframe only from receiver request / layer start — not per gate drop.
                        // (SW RequestKeyframe under scroll → ucrtbase 0xc0000409 abort.)
                        droppedSinceSend = 0;
                        if (_wantKeyframe)
                        {
                            wantVideoKeyframe = true;
                            keyframeForceSent = false;
                            _wantKeyframe = false;
                        }
                        if (useVideo && wantVideoKeyframe)
                            idrWaitFrames++;
                        else
                            idrWaitFrames = 0;
                        // Re-poke IDR sparingly — every 8 frames was RequestKeyframe spam under scroll.
                        if (useVideo && wantVideoKeyframe && idrWaitFrames > 0 && idrWaitFrames % 30 == 0)
                            keyframeForceSent = false;

                        if (useVideo)
                        {
                            // Mac order: videoParams (on IDR) → videoFrame → tileFrame (video + settled BC7).
                            var forceKey = wantVideoKeyframe && !keyframeForceSent;
                            if (forceKey)
                                keyframeForceSent = true;
                            EncodedVideoFrame? v = null;
                            try
                            {
                                v = video!.Encode(frame.Bgra, frame.Width, frame.Height, forceKey);
                            }
                            catch (Exception ex)
                            {
                                // Mac FrameStreamer.fallBackToBC1: drop video; motion continues as BC1.
                                Console.WriteLine($"[video] encode: {ex.Message}");
                                onVideo = false;
                                wantVideoKeyframe = true;
                                keyframeForceSent = false;
                                Array.Clear(stickyVideo);
                                Array.Clear(stickyClean);
                                tiles.Motion = TileMotion.Bc1;
                                var fallback = tiles.Encode(frame.Bgra, frame.Width, frame.Height, frameIndex);
                                if (fallback is not null)
                                {
                                    _conn?.Send(new Message(MessageType.TileFrame, 0, fallback.Payload));
                                    Snapshot.FramesSent++;
                                    sentFrames++;
                                    wireTileBytes += fallback.Payload.Length;
                                    rawTileBytes += fallback.Payload.Length;
                                }
                                Snapshot.State = "Streaming (video err → BC1)";
                                goto FrameDone;
                            }

                            if (IdrDiagnostics && !videoParamsSent && idrWaitFrames <= 40)
                            {
                                // Diagnostic (AFTERSCREEN_MF_VERBOSE=1): why the first IDR + parameter sets are slow.
                                Console.WriteLine(
                                    $"[idr] wait={idrWaitFrames} force={forceKey} " +
                                    (v is null ? "out=null" : $"out=key:{v.Keyframe} ps:{v.ParameterSets?.Length ?? 0} bytes:{v.Avcc.Length} nal0={(v.Avcc.Length > 4 ? (v.Avcc[4] & 0x1F) : -1)}/ref{(v.Avcc.Length > 4 ? (v.Avcc[4] >> 5) & 3 : -1)} slice={Afterscreen.Sender.Encode.MfH264Encoder.FirstSliceType(v.Avcc)}") +
                                    $" t={Environment.TickCount64 % 100000}");
                            }
                            if (v is not null)
                            {
                                videoNullStreak = 0;
                                // Hold until IDR + params. Do not clear wantVideoKeyframe on a
                                // keyframe that still lacks parameter sets (was stuck waiting forever).
                                if (v.Keyframe && v.ParameterSets is { Length: > 0 })
                                {
                                    _conn?.Send(new Message(MessageType.VideoParams, 0,
                                        VideoWire.Params(config.Video?.Codec ?? VideoCodec.h264, v.ParameterSets)));
                                    videoParamsSent = true;
                                }
                                if (wantVideoKeyframe && v.Keyframe && videoParamsSent)
                                {
                                    wantVideoKeyframe = false;
                                    keyframeForceSent = false;
                                    idrWaitFrames = 0;
                                }

                                // Prefer IDR after (re)config; QSV often yields P first — don't stall.
                                if (wantVideoKeyframe && videoParamsSent && idrWaitFrames > 8)
                                {
                                    wantVideoKeyframe = false;
                                    keyframeForceSent = false;
                                    idrWaitFrames = 0;
                                }
                                if (!videoParamsSent && idrWaitFrames > 60)
                                {
                                    // Mac fallBackToBC1 when the video layer never becomes usable.
                                    onVideo = false;
                                    Array.Clear(stickyVideo);
                                    Array.Clear(stickyClean);
                                    tiles.Motion = TileMotion.Bc1;
                                    Snapshot.State = "Streaming (IDR timeout → BC1)";
                                    goto FrameDone;
                                }
                                // Once params are on the wire, keep sending P-frames while an IDR
                                // is requested — blocking here was sentFPS 1–5 under scroll.
                                var canSend = videoParamsSent;
                                if (canSend)
                                {
                                    // Mac outbox: video + tile mask. settleLimit=0 clears sticky
                                    // without BC7 encode (Iris settle was too slow for the pair).
                                    var sceneCut = probe.DirtyShare >= sceneCutShare;
                                    var hybridMarks = BuildHybridMarks(
                                        probe.Marks, stickyVideo, stickyClean, settleCleanFrames, settleLimit,
                                        allowSettle: !settleEnabled);
                                    if (sceneCut)
                                    {
                                        for (var i = 0; i < hybridMarks.Length; i++)
                                            hybridMarks[i] = (byte)(TileFormat.Video + 1);
                                    }
                                    // Mac TileEncoder (video mode): only tiles in motion go to video; a tile that
                                    // changes after being still is sent as BC7 (while the frame's count is within
                                    // settleLimit, else by video and settled later).
                                    var hasBc7 = false;
                                    if (!sceneCut && tileClass is not null && stillCount <= settleBase)
                                    {
                                        for (var i = 0; i < tileClass.Length && i < hybridMarks.Length; i++)
                                        {
                                            if (tileClass[i] != 1) continue;
                                            hybridMarks[i] = (byte)(TileFormat.Bc7 + 1);
                                            stickyVideo[i] = false;
                                            stickyClean[i] = 0;
                                            hasBc7 = true;
                                        }
                                    }
                                    foreach (var m in hybridMarks)
                                    {
                                        if (m == (byte)(TileFormat.Bc7 + 1)) _fmtBc7++;
                                        else if (m == (byte)(TileFormat.Video + 1)) _fmtVideo++;
                                    }
                                    tiles.NotePresented(frame.Bgra);
                                    _conn?.Send(new Message(MessageType.VideoFrame, 0,
                                        VideoWire.Frame(v.Keyframe, v.Avcc)));
                                    // Mixed frame: video runs carry no data, BC7 runs carry the still tiles.
                                    byte[] tilePayload = sceneCut
                                        ? TileFrameWire.VideoPresent(frameIndex, geometry)
                                        : hasBc7
                                            ? (tiles.EncodeMarks(frame.Bgra, frame.Width, frame.Height, frameIndex, hybridMarks)?.Payload
                                               ?? TileFrameWire.VideoMask(frameIndex, geometry, hybridMarks))
                                            : TileFrameWire.VideoMask(frameIndex, geometry, hybridMarks);
                                    _conn?.Send(new Message(MessageType.TileFrame, 0, tilePayload));
                                    Snapshot.FramesSent++;
                                    sentFrames++;
                                    Snapshot.State = $"Streaming (video {(v.Keyframe ? "IDR" : "P")})";
                                }
                                else
                                {
                                    // Waiting first IDR/params — BC1 tiles so sentFPS is not zero.
                                    var saved = tiles.Motion;
                                    tiles.Motion = TileMotion.Bc1;
                                    EncodedTileFrame? keep;
                                    try { keep = tiles.Encode(frame.Bgra, frame.Width, frame.Height, frameIndex); }
                                    finally { tiles.Motion = saved; }
                                    if (keep is not null)
                                    {
                                        _conn?.Send(new Message(MessageType.TileFrame, 0, keep.Payload));
                                        Snapshot.FramesSent++;
                                        sentFrames++;
                                        wireTileBytes += keep.Payload.Length;
                                        rawTileBytes += keep.Payload.Length;
                                    }
                                    Snapshot.State = "Streaming (video waiting IDR)";
                                }
                            }
                            else
                            {
                                // Async QSV often returns null while a prior input is in flight —
                                // that is lag, not a dead layer. Require a long drought.
                                videoNullStreak++;
                                if (videoNullStreak >= 90)
                                {
                                    // Mac FrameStreamer.fallBackToBC1 — layer stopped producing.
                                    onVideo = false;
                                    wantVideoKeyframe = true;
                                    keyframeForceSent = false;
                                    videoParamsSent = false;
                                    videoNullStreak = 0;
                                    Array.Clear(stickyVideo);
                                    Array.Clear(stickyClean);
                                    tiles.Motion = TileMotion.Bc1;
                                    Snapshot.State = "Streaming (video null → BC1)";
                                    goto FrameDone;
                                }
                                var saved = tiles.Motion;
                                tiles.Motion = TileMotion.Bc1;
                                EncodedTileFrame? keep;
                                try { keep = tiles.Encode(frame.Bgra, frame.Width, frame.Height, frameIndex); }
                                finally { tiles.Motion = saved; }
                                if (keep is not null)
                                {
                                    _conn?.Send(new Message(MessageType.TileFrame, 0, keep.Payload));
                                    Snapshot.FramesSent++;
                                    sentFrames++;
                                    wireTileBytes += keep.Payload.Length;
                                    rawTileBytes += keep.Payload.Length;
                                }
                                Snapshot.State = "Streaming (video null)";
                            }
                        }
                        else
                        {
                            // Still UI: BC1/BC7 tiles only — Motion.Video would emit .video
                            // runs without a VideoFrame (stale soft picture).
                            // Per-tile like Mac (no video layer on this frame): tiles that change after being still go
                            // out as BC7 right away (typing, a menu, a click); tiles that keep changing stay BC7 while
                            // their count is within the link's BC7 budget and drop to BC1 beyond it (they settle when
                            // they stop). On this gigabit link ~236 moving tiles per frame stay sharp.
                            byte[]? directMarks = null;
                            if (tileClass is not null)
                            {
                                directMarks = new byte[tileClass.Length];
                                var stillBc7 = stillCount <= settleBase;
                                var movingBc7 = movingCount <= bc7MotionLimit;
                                for (var i = 0; i < tileClass.Length; i++)
                                {
                                    if (tileClass[i] == 0) continue;
                                    var sharp = tileClass[i] == 1 ? stillBc7 : movingBc7;
                                    directMarks[i] = (byte)(sharp ? TileFormat.Bc7 + 1 : TileFormat.Bc1 + 1);
                                    if (sharp) _fmtBc7++; else _fmtBc1++;
                                }
                            }
                            EncodedTileFrame? tile;
                            if (directMarks is not null)
                            {
                                tile = tiles.EncodeMarks(frame.Bgra, frame.Width, frame.Height, frameIndex, directMarks);
                                tiles.NotePresented(frame.Bgra); // commit the changed tiles to the reference
                            }
                            else
                            {
                                var savedMotion = tiles.Motion;
                                tiles.Motion = TileMotion.Bc1;
                                try
                                {
                                    tile = tiles.Encode(frame.Bgra, frame.Width, frame.Height, frameIndex);
                                }
                                finally
                                {
                                    tiles.Motion = savedMotion;
                                }
                            }
                            if (tile is not null)
                            {
                                _conn?.Send(new Message(MessageType.TileFrame, 0, tile.Payload));
                                Snapshot.FramesSent++;
                                sentFrames++;
                                wireTileBytes += tile.Payload.Length;
                                rawTileBytes += tile.Payload.Length;
                                Snapshot.State = tile.Keyframe
                                    ? $"Streaming (keyframe {tiles.BackendName})"
                                    : $"Streaming (dirty {tile.DirtyTiles}/{tile.TotalTiles})";
                            }
                            else
                            {
                                _conn?.Send(new Message(MessageType.TileFrame, 0, TileFrameWire.Empty(frameIndex, geometry)));
                                Snapshot.FramesSent++;
                                sentFrames++;
                                Snapshot.State = "Streaming (quiet)";
                            }
                        }
                    FrameDone: ;
                        encSw.Stop();
                        encodeMsSum += encSw.Elapsed.TotalMilliseconds;
                        encodedFrames++;
                    }

                    FlushSenderStats(ref statsAt, ref encodeMsSum, ref encodedFrames, ref dirtyTilesSum, ref dirtySamples,
                        ref rawTileBytes, ref wireTileBytes, ref sentFrames, ref captureFrames, ref droppedFrames,
                        stickyVideo, config);

                    if (Snapshot.FramesSent > 0 && Snapshot.FramesSent % 30 == 0)
                        Publish();
                }
                catch (Exception ex)
                {
                    End("stream: " + ex.Message);
                    break;
                }
            }
            capture?.Dispose();
        }
    }

    /// <summary>Mac SenderSession.sampleTelemetry — 1 Hz SenderStats for Receiver HUD.</summary>
    // Inter-arrival jitter trackers (ms between captured frames / sent video frames), reported per stats interval.
    // Thread-safe: the capture thread notes, the stream loop takes.
    private sealed class IntervalTrack
    {
        private readonly List<double> _v = new();
        private long _last;
        public void Note()
        {
            var t = System.Diagnostics.Stopwatch.GetTimestamp();
            lock (_v)
            {
                if (_last != 0) _v.Add(System.Diagnostics.Stopwatch.GetElapsedTime(_last, t).TotalMilliseconds);
                _last = t;
            }
        }
        public string Take(string name)
        {
            lock (_v)
            {
                if (_v.Count == 0) return "";
                _v.Sort();
                var r = $" {name}[n={_v.Count} p50={_v[_v.Count / 2]:0} p95={_v[(int)(_v.Count * 0.95)]:0} max={_v[^1]:0}]";
                _v.Clear();
                return r;
            }
        }
    }
    private readonly IntervalTrack _capIv = new(), _vidIv = new();
    private readonly QualityNotice _qualityNotice = new();
    private readonly GpuMeter _gpuMeter = new();
    private static double? _lastQualityNotice;
    // From the 4x/s TCP_INFO samples of the Mac loop
    private double? _rttMs;
    private double _jitterMs;
    private double _retransmitPercent;

    private void FlushSenderStats(
        ref long statsAt, ref double encodeMsSum, ref int encodedFrames,
        ref int dirtyTilesSum, ref int dirtySamples,
        ref long rawTileBytes, ref long wireTileBytes,
        ref int sentFrames, ref int captureFrames, ref int droppedFrames,
        bool[] stickyVideo, StreamConfig config)
    {
        var now = Environment.TickCount64;
        var elapsed = now - statsAt;
        if (elapsed < 1000 || _conn is null || _conn.IsClosed)
            return;
        var seconds = elapsed / 1000.0;
        var bytes = _conn.TakeBytesSent();
        var lossy = 0;
        if (_macTile is { } macTile)
            lossy = macTile.LossyTiles;
        else
            foreach (var s in stickyVideo)
                if (s) lossy++;
        var bc1Tiles = 0;
        foreach (var b in _tilesRef?.LossyBc1 ?? Array.Empty<bool>())
            if (b) bc1Tiles++;
        long mem = 0;
        double cpu = 0;
        try
        {
            var proc = System.Diagnostics.Process.GetCurrentProcess();
            mem = proc.WorkingSet64;
            var cpuNow = proc.TotalProcessorTime;
            if (_lastCpuSampleMs > 0)
            {
                var wallMs = Math.Max(1, now - _lastCpuSampleMs);
                var cpuMs = (cpuNow - _lastCpuTime).TotalMilliseconds;
                cpu = Math.Clamp(cpuMs / wallMs / Math.Max(1, Environment.ProcessorCount) * 100.0, 0, 100);
            }
            _lastCpuTime = cpuNow;
            _lastCpuSampleMs = now;
        }
        catch { /* ignore */ }
        var stats = new SenderStats
        {
            Interface = Snapshot.Interface ?? _routeInterface ?? _linkKind.ToString(),
            CapacityGbps = Snapshot.CapacityGbps,
            ThroughputBitsPerSecond = bytes * 8.0 / seconds,
            LatencyMs = _rttMs,
            JitterMs = _jitterMs,
            RetransmitPercent = _retransmitPercent,
            CableScore = Afterscreen.Protocol.CableScore.Score(_retransmitPercent, _jitterMs, Snapshot.CapacityGbps, Afterscreen.Protocol.CableScore.RequiredGbps(config)),
            CaptureFPS = captureFrames / seconds,
            SentFPS = sentFrames / seconds,
            DroppedPerMinute = (int)(droppedFrames / seconds * 60),
            DirtyPercent = dirtySamples > 0 ? dirtyTilesSum / (double)dirtySamples / Math.Max(1, stickyVideo.Length) * 100 : 0,
            CompressionRatio = wireTileBytes > 0 && rawTileBytes > 0 ? rawTileBytes / (double)wireTileBytes : 0,
            EncodeMs = encodedFrames > 0 ? encodeMsSum / encodedFrames : 0,
            LossyTiles = lossy,
            CpuPercent = cpu,
            MemoryBytes = (ulong)Math.Max(0, mem),
            GpuPercent = _gpuMeter.PercentSinceLastRead(),
            VideoBitrate = Snapshot.VideoBitrate ?? config.Video?.Bitrate,
            FlashBlocks = FlashBlocks ? true : null,
            Language = "ko",
        };
        try { _conn.Send(JsonWire.Message(MessageType.SenderStats, stats)); }
        catch { /* ignore */ }
        // Mac: tell the receiver once when the picture has been turned down severely and for long (quiet for 10 min after)
        var notice = false;
        if (Snapshot is { VideoBitrate: { } vbNow, VideoStartBitrate: { } vbStart })
        {
            notice = _qualityNotice.Update(vbNow, vbStart, Environment.TickCount64 / 1000.0, ref _lastQualityNotice);
            Snapshot.QualityLowered = _qualityNotice.Lowered;
        }
        stats.CongestionNotice = notice ? true : null;
        if (notice) Console.WriteLine($"[quality] the picture has been turned down (video {Snapshot.VideoBitrate / 1_000_000} of {Snapshot.VideoStartBitrate / 1_000_000} Mbps): telling the receiver");
        Snapshot.Stats = stats;
        Snapshot.State =
            $"sent={stats.SentFPS:0.0}fps enc={stats.EncodeMs:0.0}ms " +
            $"cap={stats.CaptureFPS:0.0} drop={stats.DroppedPerMinute}/m " +
            $"qf={_conn.QueuedFrames} qm={_conn.QueuedMessages} ws={mem / (1024 * 1024)}MB gc={GC.GetTotalMemory(false) / (1024 * 1024)}MB lossy={lossy} bc1={bc1Tiles} fmt[bc7={_fmtBc7} bc1={_fmtBc1} vid={_fmtVideo}] cls[still={_clsStill} moving={_clsMoving}] cpu={cpu:0}% gpu={stats.GpuPercent:0}% rtt={_rttMs ?? 0:0.0}ms jit={_jitterMs:0.0} re={_retransmitPercent:0.0}% score={stats.CableScore} vb={(Snapshot.VideoBitrate ?? 0) / 1000000}M if={stats.Interface}" + (Snapshot.Receiver?.AudioBufferMs is { } ab ? $" audio={ab:0}ms/{Snapshot.Receiver.AudioUnderruns}u" : "");
        _fmtBc7 = _fmtBc1 = _fmtVideo = _clsStill = _clsMoving = 0;
        // Step-0 stage timings (ms per frame): GPU->CPU readback, CPU scale, dirty Probe.
        if (_dxgi is { } dx)
        {
            var (rb, sc) = dx.TakeTimings();
            var pr = _probeN > 0 ? _probeMsSum / _probeN : 0;
            Snapshot.State += $" rb={rb:0.0} sc={sc:0.0} probe={pr:0.0}";
            // Capture thread: ms issuing a frame's copies, polls skipped while an encode held the context (per second)
            var (cc, cn, cbusy) = dx.TakeCopyTimings();
            if (cn > 0 || cbusy > 0)
                Snapshot.State += $" cc={cc:0.00} cbusy={cbusy}";
        }
        if (_videoRef is Encode.MfH264Encoder mf)
        {
            var (vs, vn, vp, vq) = mf.TakeStageTimings();
            var lat = mf.TakeOutputLatency();
            if (vs + vn + vp + vq > 0)
                Snapshot.State += $" v[scale={vs:0.0} nv12={vn:0.0} copy={vp:0.0} submit={vq:0.0} lat={lat:0.0}]";
            // VIDEO_DIAG (default on): GPU→CPU NV12 path breakdown for zero-copy planning.
            // vd[cs=compute gpu=Copy+Flush map=Map(Read) cpy=MemoryCopy n=frames B=NV12 bytes path=sysmem|dxgi]
            if (!string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_VIDEO_DIAG"), "0", StringComparison.Ordinal))
            {
                var (cs, gpu, map, cpy, vnFrames, nv12Bytes) = mf.TakeConvertDiag();
                if (vnFrames > 0)
                {
                    var mbs = nv12Bytes * vnFrames / (1024.0 * 1024.0);
                    Snapshot.State +=
                        $" vd[cs={cs:0.00} gpu={gpu:0.00} map={map:0.00} cpy={cpy:0.00} n={vnFrames} B={nv12Bytes} MB/s={mbs:0.0} path={mf.InputPathTag} abl={mf.ConvertAblationTag}]";
                }
            }
        }
        if (_tileN > 0)
            Snapshot.State += $" tile={_tileMsSum / _tileN:0.0}";
        _tileMsSum = 0;
        _tileN = 0;
        Snapshot.State += _capIv.Take("ci") + _vidIv.Take("vi");
        AppendStatsLog(Snapshot.State);
        _probeMsSum = 0;
        _probeN = 0;
        Publish();
        statsAt = now;
        encodeMsSum = 0;
        encodedFrames = 0;
        dirtyTilesSum = 0;
        dirtySamples = 0;
        rawTileBytes = 0;
        wireTileBytes = 0;
        sentFrames = 0;
        captureFrames = 0;
        droppedFrames = 0;
    }

    private static string? _statsLogPath;

    /// <summary>
    /// One stats line a second to %LocalAppData%\AfterscreenSender\stream-stats.log, so the windowed app (no
    /// console) can be measured; rolled over to stream-stats.1.log at 4 MB.
    /// </summary>
    private static void AppendStatsLog(string line)
    {
        try
        {
            _statsLogPath ??= Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AfterscreenSender", "stream-stats.log");
            Directory.CreateDirectory(Path.GetDirectoryName(_statsLogPath)!);
            var info = new FileInfo(_statsLogPath);
            if (info.Exists && info.Length > 4 * 1024 * 1024)
                File.Move(_statsLogPath, Path.ChangeExtension(_statsLogPath, ".1.log"), overwrite: true);
            File.AppendAllText(_statsLogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
        }
        catch { /* stats are best effort */ }
    }

    /// <summary>
    /// Dirty → sticky video (mark 3). Sticky clean for settleCleanFrames → BC7 (mark 1) and leave sticky.
    /// </summary>
    private static byte[] BuildHybridMarks(
        byte[]? dirtyMarks, bool[] sticky, int[] stickyClean, int settleCleanFrames, int settleLimit,
        bool allowSettle = true)
    {
        var marks = new byte[sticky.Length];
        var settling = 0;
        for (var i = 0; i < sticky.Length; i++)
        {
            var dirty = dirtyMarks is not null && i < dirtyMarks.Length && dirtyMarks[i] != 0;
            if (dirty)
            {
                sticky[i] = true;
                stickyClean[i] = 0;
                marks[i] = (byte)(TileFormat.Video + 1);
                continue;
            }

            if (!sticky[i])
                continue;

            stickyClean[i]++;
            if (stickyClean[i] < settleCleanFrames)
            {
                marks[i] = (byte)(TileFormat.Video + 1);
                continue;
            }
            // Mac refine() settles on an idle link. Video pairs pass allowSettle=false
            // so sticky stays video-masked until refine emits BC7.
            if (allowSettle && settleLimit > 0 && settling < settleLimit)
            {
                sticky[i] = false;
                stickyClean[i] = 0;
                marks[i] = (byte)(TileFormat.Bc7 + 1);
                settling++;
            }
            else if (allowSettle && settleLimit <= 0)
            {
                sticky[i] = false;
                stickyClean[i] = 0;
            }
            else
            {
                marks[i] = (byte)(TileFormat.Video + 1);
            }
        }
        return marks;
    }

    private Pairing.Transcript Transcript(Welcome welcome) =>
        new(_senderId, welcome.ReceiverID ?? "", _helloNonce, welcome.Auth?.Nonce ?? Array.Empty<byte>());

    private void Set(SessionPhase phase, string state)
    {
        Snapshot.Phase = phase;
        Snapshot.State = state;
        Publish();
    }

    private void Publish() => OnUpdate?.Invoke(Snapshot);

    /// <summary>
    /// Mac <c>close(power:)</c>: PowerOff with optional receiver power, then the caller ends the session
    /// (Bye still goes out from <see cref="End"/>). No-op when not streaming.
    /// </summary>
    public void SendPowerOff(string reason, ReceiverPower? power)
    {
        if (Snapshot.Phase != SessionPhase.Streaming || TestMode) return;
        try
        {
            _conn?.Send(JsonWire.Message(MessageType.PowerOff, new Bye { Reason = reason, Power = power }));
            Console.WriteLine($"[power] PowerOff power={power?.ToString() ?? "null"}");
        }
        catch { /* ignore */ }
    }

    private void End(string reason)
    {
        _stopping = true;
        if (Snapshot.Phase == SessionPhase.Ended)
        {
            _ended.TrySetResult();
            return;
        }
        Snapshot.Phase = SessionPhase.Ended;
        Snapshot.State = reason;
        Publish();
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "AfterscreenSender");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "last-end.txt"),
                $"{DateTime.Now:o}\n{reason}\nframes={Snapshot.FramesSent}\n");
        }
        catch { /* ignore */ }
        try { Console.Out.Flush(); } catch { /* ignore */ }
        StopKeepalive();
        StopRouteWatch();
        try { _streamCts?.Cancel(); } catch { /* ignore */ }
        try { _cursor?.Dispose(); } catch { /* ignore */ }
        _cursor = null;
        try { _cursorConn?.Dispose(); } catch { /* ignore */ }
        _cursorConn = null;
        try { _conn?.Send(JsonWire.Message(MessageType.Bye, new Bye { Reason = reason })); } catch { /* ignore */ }
        try { _conn?.Dispose(); } catch { /* ignore */ }
        _conn = null;
        _ended.TrySetResult();
    }

    public void Dispose()
    {
        try { StopBrightnessFollow(); } catch { /* ignore */ }
        try { StopSound(); } catch { /* ignore */ }
        try { _gpuMeter.Dispose(); } catch { /* ignore */ }
        End("disposed");
        try { _conn?.Dispose(); } catch { /* ignore */ }
    }
}
