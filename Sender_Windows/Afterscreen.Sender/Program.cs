using System.Runtime.InteropServices;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Session;
using Afterscreen.Sender.Testing;

// Monitor geometry (DXGI desktop coordinates, the cursor position) must be in physical pixels. A process
// that is not DPI aware gets virtualized sizes: a 3840x2160 monitor at 150% scale reads as 2560x1440,
// which sizes the capture wrong and puts the cursor at the wrong place.
SenderNative.EnablePerMonitorDpiAwareness();

static string AppData() =>
    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AfterscreenSender");

static string SenderId()
{
    Directory.CreateDirectory(AppData());
    var path = Path.Combine(AppData(), "sender-id.txt");
    if (File.Exists(path))
        return File.ReadAllText(path).Trim();
    var id = Guid.NewGuid().ToString("N");
    File.WriteAllText(path, id);
    return id;
}

static void Usage()
{
    Console.WriteLine(
        """
        Afterscreen Windows Sender

          fake-receiver [--port N]          local Mac-Receiver stand-in
          self-test                         fake-receiver + pair + stub stream (loopback)
          stream <host> <port> [code]       connect to real/fake receiver
          capture-once [out.bgra]           DXGI grab → 2880x1620 (smoke)
          monitors                          list DXGI outputs and the one AFTERSCREEN_OUTPUT selects
          encode-smoke                      list GPUs + try MF H.264 once
          dxgi-prove                        Phase A: FORCE_DXGI + texture-sample prove (does not touch live App)
        """);
}

if (args.Length == 0)
{
    Usage();
    return 1;
}

return args[0] switch
{
    "fake-receiver" => await RunFakeReceiver(args),
    "self-test" => await RunSelfTest(),
    "stream" => await RunStream(args),
    "capture-once" => RunCaptureOnce(args),
    "encode-smoke" => RunEncodeSmoke(),
    "monitors" => RunMonitors(),
    "bc7-bench" => RunBc7Bench(args.Length > 1 && int.TryParse(args[1], out var bw) ? bw : 3840, args.Length > 2 && int.TryParse(args[2], out var bh) ? bh : 2160),
    "enc-capacity" => RunEncCapacity(),
    "discover" => await RunDiscover(),
    "idr-probe" => RunIdrProbe(args.Length > 1 && int.TryParse(args[1], out var iv) ? iv : 1),
    "dxgi-prove" => RunDxgiProve(),
    _ => FailUsage(),
};

static int FailUsage()
{
    Usage();
    return 1;
}

static async Task<int> RunFakeReceiver(string[] args)
{
    var port = 0;
    var open = false;
    for (var i = 1; i < args.Length; i++)
    {
        if (args[i] == "--port" && i + 1 < args.Length && int.TryParse(args[i + 1], out var p))
            port = p;
        if (args[i] == "--open") open = true;
    }

    using var fake = new FakeReceiver(port) { OpenAdmission = open };
    fake.Start();
    Console.WriteLine($"fake-receiver listening on 127.0.0.1:{fake.Port} open={open}");
    Console.WriteLine("Ctrl+C to stop");
    await Task.Delay(Timeout.Infinite);
    return 0;
}

static async Task<int> RunSelfTest()
{
    // Skip encoder capacity measurement — self-test only needs pair/config/tiles.
    Environment.SetEnvironmentVariable("AFTERSCREEN_CAPACITY",
        Environment.GetEnvironmentVariable("AFTERSCREEN_CAPACITY") ?? "0");
    var storeR = new MemoryPairingStore();
    var storeS = new MemoryPairingStore();
    using var fake = new FakeReceiver(0, storeR);
    fake.Start();
    Console.WriteLine($"self-test: fake receiver :{fake.Port}");

    var senderId = "self-test-sender";
    string? code = null;
    // Capture must be on: EnableCapture=false left StreamLoop with no frames after the Mac GPU path
    // became default. Loopback + real DXGI is enough for pair/config/tiles.
    using var session = new SenderSession("127.0.0.1", fake.Port, senderId, storeS, LinkKind.loopback)
    {
        EnableCapture = true,
        CodeProvider = () =>
        {
            for (var i = 0; i < 50 && fake.ShownCode is null; i++)
                Thread.Sleep(20);
            code = fake.ShownCode ?? throw new InvalidOperationException("no code shown");
            Console.WriteLine("self-test: using code from fake receiver");
            return code;
        },
    };
    session.OnUpdate += s => Console.WriteLine($"  [{s.Phase}] {s.State} frames={s.FramesSent}");

    using var cts = new CancellationTokenSource();
    var run = session.RunAsync(cts.Token);
    // Pair + probe + MF pipeline can take several seconds; wait for tiles after Config.
    for (var i = 0; i < 400 && fake.Configs < 1; i++)
        await Task.Delay(25);
    for (var i = 0; i < 400 && fake.TileFrames < 5; i++)
        await Task.Delay(25);
    Console.WriteLine($"self-test: stopping (configs={fake.Configs} tiles={fake.TileFrames} video={fake.VideoFrames})");
    session.Dispose();
    try { await run.WaitAsync(TimeSpan.FromSeconds(3)); }
    catch (Exception ex) { Console.WriteLine($"self-test: stop ({ex.GetType().Name})"); }

    Console.WriteLine($"self-test: tiles={fake.TileFrames} configs={fake.Configs} state={fake.State} framesSent={session.Snapshot.FramesSent}");
    if (fake.Configs < 1 || fake.TileFrames < 1)
    {
        Console.Error.WriteLine("self-test FAILED");
        return 1;
    }
    Console.WriteLine("self-test OK");
    return 0;
}

static async Task<int> RunStream(string[] args)
{
    if (args.Length < 3)
    {
        Usage();
        return 1;
    }
    var host = args[1];
    IReadOnlyList<string> peerAddrs = Array.Empty<string>();
    string? peerDeviceId = null;
    string? peerName = null;
    if (host == "auto")
    {
        // Bonjour: the first receiver found, at its current (temporary) port, over the fastest link that answers
        using var discovery = new Afterscreen.Sender.Session.Discovery();
        var found = await discovery.ScanNowAsync();
        if (found.Count == 0) { Console.Error.WriteLine("no receiver found"); return 1; }
        var pick = found[0];
        peerAddrs = pick.Addresses;
        peerDeviceId = pick.DeviceId;
        peerName = pick.Name;
        var preferred = Environment.GetEnvironmentVariable("AFTERSCREEN_LINK") ?? "auto";
        var planned = RoutePlanner.PickDetailed(
            RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList(),
            peerAddrs, preferred);
        var addr = planned.Address.Length > 0 ? planned.Address : pick.Address;
        Console.WriteLine($"[discovery] {pick.Name} at {addr}:{pick.Port} link={planned.Got} id={pick.DeviceId}");
        args = new[] { args[0], addr, pick.Port.ToString() }.Concat(args.Skip(3)).ToArray();
        host = args[1];
    }
    if (!int.TryParse(args[2], out var port))
    {
        Console.Error.WriteLine("bad port");
        return 1;
    }
    if (peerAddrs.Count == 0) peerAddrs = new[] { host };
    var store = new FilePairingStore(AppData());
    var codeFile = Path.Combine(AppData(), "pending-code.txt");
    try { File.Delete(codeFile); } catch { /* ignore */ }
    var preferredLink = Environment.GetEnvironmentVariable("AFTERSCREEN_LINK") ?? "auto";
    var linkPick = RoutePlanner.PickDetailed(
        RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList(),
        peerAddrs, preferredLink);
    var link = linkPick.Got
        ?? (host.StartsWith("169.254.", StringComparison.Ordinal) ? LinkKind.ethernet : LinkKind.wifi);
    if (linkPick.Address.Length > 0) host = linkPick.Address;
    Console.WriteLine($"[route] host={host} link={link} prefer={preferredLink}");
    Func<string> codeProvider = () =>
    {
        if (args.Length >= 4 && args[3].Length == 6)
            return args[3];
        // Wait as long as needed — a timed-out wait ends the session and the receiver drops the code.
        Console.WriteLine($"waiting for pairing code (write 6 digits to {codeFile}, or type here) …");
        while (true)
        {
            try
            {
                if (File.Exists(codeFile))
                {
                    var c = File.ReadAllText(codeFile).Trim();
                    if (c.Length == 6)
                    {
                        try { File.Delete(codeFile); } catch { /* ignore */ }
                        return c;
                    }
                }
            }
            catch { /* ignore */ }
            try
            {
                if (Console.KeyAvailable)
                {
                    Console.Write("pairing code: ");
                    return Console.ReadLine()?.Trim() ?? "";
                }
            }
            catch (InvalidOperationException)
            {
                // Redirected stdout/stdin (agent logs): only pending-code.txt works.
            }
            Thread.Sleep(200);
        }
    };
    var endLog = Path.Combine(AppData(), "last-end.txt");
    AppDomain.CurrentDomain.UnhandledException += (_, e) =>
    {
        try
        {
            File.WriteAllText(endLog, $"{DateTime.Now:o}\nunhandled: {e.ExceptionObject}\n");
            Console.WriteLine($"[Ended] unhandled: {e.ExceptionObject}");
            Console.Out.Flush();
        }
        catch { /* ignore */ }
    };
    AppDomain.CurrentDomain.ProcessExit += (_, _) =>
    {
        try
        {
            if (!File.Exists(endLog))
                File.WriteAllText(endLog, $"{DateTime.Now:o}\nprocess-exit\n");
        }
        catch { /* ignore */ }
    };
    TaskScheduler.UnobservedTaskException += (_, e) =>
    {
        try
        {
            File.AppendAllText(endLog, $"{DateTime.Now:o}\nunobserved: {e.Exception}\n");
            e.SetObserved();
        }
        catch { /* ignore */ }
    };
    Console.WriteLine($"OS={RuntimeInformation.OSDescription}");
    // Mac AppModel: Bye.relink → open a fresh session (stale receiver giveWay).
    SenderSnapshot? last = null;
    for (var attempt = 1; attempt <= 6; attempt++)
    {
        using var session = new SenderSession(host, port, SenderId(), store, link)
        {
            CodeProvider = codeProvider,
            TestMode = Environment.GetEnvironmentVariable("AFTERSCREEN_TEST") == "1",
            Sound = Environment.GetEnvironmentVariable("AFTERSCREEN_SOUND") == "1",
            // null = follow PC panel (Mac brightnessFollows); AFTERSCREEN_BRIGHTNESS_FOLLOW=0 keeps manual 0.8
            OwnBrightness = Environment.GetEnvironmentVariable("AFTERSCREEN_BRIGHTNESS_FOLLOW") == "0" ? 0.8 : null,
            PeerAddresses = peerAddrs,
            PeerDeviceId = peerDeviceId,
            PeerName = peerName,
        };
        session.OnUpdate += s =>
        {
            Console.WriteLine($"[{s.Phase}] {s.State}");
            try { Console.Out.Flush(); } catch { /* ignore */ }
        };
        using var runCts = new CancellationTokenSource();
        // Dev: AFTERSCREEN_SECONDS=N ends the stream after N seconds of Streaming.
        // Do not cancel while Pairing — the user may need as long as they want to type the code
        // (canceling here made the receiver's code vanish). AFTERSCREEN_END_POWER=sleep|shutDown|keepOn.
        if (int.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_SECONDS"), out var secs) && secs > 0)
        {
            var endPower = Environment.GetEnvironmentVariable("AFTERSCREEN_END_POWER");
            _ = Task.Run(async () =>
            {
                try
                {
                    while (session.Snapshot.Phase is not SessionPhase.Streaming and not SessionPhase.Ended)
                        await Task.Delay(100).ConfigureAwait(false);
                    if (session.Snapshot.Phase != SessionPhase.Streaming) return;
                    await Task.Delay(Math.Max(0, secs) * 1000).ConfigureAwait(false);
                    if (!string.IsNullOrEmpty(endPower))
                    {
                        ReceiverPower? power = endPower switch
                        {
                            "sleep" => ReceiverPower.sleep,
                            "shutDown" => ReceiverPower.shutDown,
                            _ => null,
                        };
                        session.SendPowerOff("Disconnect", power);
                        await Task.Delay(3000).ConfigureAwait(false);
                    }
                }
                catch { /* ignore */ }
                try { runCts.Cancel(); } catch { /* ignore */ }
            });
        }
        try
        {
            await session.RunAsync(runCts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.WriteLine("[Ended] connect canceled/timeout");
            return 1;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Ended] {ex.GetType().Name}: {ex.Message}");
            try { File.AppendAllText(endLog, $"{DateTime.Now:o}\n{ex}\n"); } catch { /* ignore */ }
            return 1;
        }
        last = session.Snapshot;
        Console.WriteLine($"[done] phase={last.Phase} frames={last.FramesSent} state={last.State}");
        if (!last.WantRelink || attempt == 6)
            break;
        Console.WriteLine($"[relink] receiver asked back — retry {attempt + 1}/6");
        await Task.Delay(400);
    }
    return last is { Phase: SessionPhase.Ended, FramesSent: > 0 } ? 0 : 1;
}

static int RunCaptureOnce(string[] args)
{
    var outPath = args.Length >= 2 ? args[1] : Path.Combine(AppData(), "capture-2880x1620.bgra");
    using var cap = new DxgiCapture(2880, 1620);
    Console.WriteLine("starting DXGI duplication…");
    cap.Start();
    CapturedFrame? frame = null;
    for (var i = 0; i < 120 && frame is null; i++)
    {
        if (cap.TryCapture(out frame))
            break;
        Thread.Sleep(16);
    }
    if (frame is null)
    {
        Console.Error.WriteLine("no frame (desktop idle or access denied)");
        return 1;
    }
    Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
    File.WriteAllBytes(outPath, frame.Bgra);
    Console.WriteLine($"wrote {frame.Width}x{frame.Height} BGRA ({frame.Bgra.Length} bytes) → {outPath}");
    return 0;
}

static int RunBc7Bench(int w, int h)
{
    // Dev: how long the GPU takes to BC7-encode N tiles (what the Mac TileEncoder does for every candidate tile).
    var enc = Afterscreen.Sender.Encode.D3dTileEncoder.TryCreate(Afterscreen.Sender.Encode.GpuAdapters.Prefer(), w, h);
    if (enc is null) { Console.WriteLine("no D3D tile encoder"); return 1; }
    var g = new TileGeometry(w, h);
    var bgra = new byte[w * h * 4];
    new Random(7).NextBytes(bgra);                      // worst case: noise, every block is hard
    foreach (var n in new[] { 32, 96, 256, 512, g.TileCount })
    {
        var marks = new byte[g.TileCount];
        for (var i = 0; i < n; i++) marks[i * g.TileCount / n] = (byte)(TileFormat.Bc7 + 1);
        for (var warm = 0; warm < 2; warm++) enc.EncodeMarks(bgra, w, h, 0, marks);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        const int reps = 5;
        for (var r = 0; r < reps; r++) enc.EncodeMarks(bgra, w, h, 0, marks);
        var ms = sw.Elapsed.TotalMilliseconds / reps;
        Console.WriteLine($"{w}x{h}: {n,5} tiles BC7 -> {ms,7:0.0} ms per call  ({ms / n * 1000,6:0.0} us/tile)");
    }
    enc.Dispose();
    return 0;
}

static int RunMonitors()
{
    var outputs = Afterscreen.Sender.Capture.DxgiCapture.ListOutputs();
    var spec = Environment.GetEnvironmentVariable("AFTERSCREEN_OUTPUT");
    var selected = Afterscreen.Sender.Capture.DxgiCapture.SelectOutput(outputs, spec);
    Console.WriteLine($"AFTERSCREEN_OUTPUT = {(string.IsNullOrEmpty(spec) ? "(unset = primary)" : spec)}");
    for (var i = 0; i < outputs.Count; i++)
        Console.WriteLine($"  [{i}] {(ReferenceEquals(outputs[i], selected) ? "*" : " ")} {outputs[i]}");
    Console.WriteLine(selected is null ? "selected: NONE" : $"selected: {selected}");
    return selected is null ? 1 : 0;
}

static async Task<int> RunDiscover()
{
    // Dev: list the receivers Bonjour finds (Mac Discovery)
    using var d = new Afterscreen.Sender.Session.Discovery();
    var list = await d.ScanNowAsync();
    if (list.Count == 0) { Console.WriteLine("no receiver found"); return 1; }
    foreach (var r in list)
        Console.WriteLine($"{r.Name} | {string.Join(",", r.Addresses)}:{r.Port} | model={r.Model} panel={r.Panel} id={r.DeviceId}");
    return 0;
}

static int RunEncCapacity()
{
    // Dev: frames per second the hardware encoder sustains per video layer size (Mac EncoderCapacity)
    var prefer = Afterscreen.Sender.Encode.GpuAdapters.Prefer();
    using var d3d = Afterscreen.Sender.Encode.D3dEncodeDevice.TryCreate(prefer);
    foreach (var (codec, ten) in new[] { (Afterscreen.Protocol.VideoCodec.hevc, true), (Afterscreen.Protocol.VideoCodec.hevc, false), (Afterscreen.Protocol.VideoCodec.h264, false) })
        foreach (var size in new[] { new Afterscreen.Protocol.PixelSize(3840, 2160), new(2880, 1620), new(2560, 1440), new(1920, 1080) })
        {
            var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
            var fps = Afterscreen.Sender.Encode.EncoderCapacity.FramesPerSecond(size, codec, ten, 80_000_000, 60, prefer, d3d);
            Console.WriteLine($"  {codec}{(ten ? " 10-bit" : "")} {size.Width}x{size.Height}: {fps:0.0} fps (took {System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalSeconds:0.0} s)");
        }
    return 0;
}

/// <summary>Phase A: prove QSV with real DXGI NV12/P010 texture samples (AFTERSCREEN_MF_FORCE_DXGI=1).</summary>
static int RunDxgiProve()
{
    Environment.SetEnvironmentVariable("AFTERSCREEN_MF_FORCE_DXGI", "1");
    Environment.SetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE", "1");
    var prefer = Afterscreen.Sender.Encode.GpuAdapters.Prefer();
    using var d3d = Afterscreen.Sender.Encode.D3dEncodeDevice.TryCreate(prefer);
    if (d3d is null) { Console.WriteLine("FAIL d3d unavailable"); return 1; }
    Console.WriteLine($"d3d: {d3d.Adapter.Description}");
    var cases = new (string name, Afterscreen.Protocol.VideoCodec codec, bool ten, int w, int h)[]
    {
        ("hevc10-2880", Afterscreen.Protocol.VideoCodec.hevc, true, 2880, 1620),
        ("hevc8-2880", Afterscreen.Protocol.VideoCodec.hevc, false, 2880, 1620),
        ("hevc10-1280", Afterscreen.Protocol.VideoCodec.hevc, true, 1280, 720),
        ("h264-1280", Afterscreen.Protocol.VideoCodec.h264, false, 1280, 720),
    };
    var anyDxgi = false;
    var anyOk = false;
    foreach (var c in cases)
    {
        var layer = new Afterscreen.Protocol.VideoLayer
        {
            Codec = c.codec,
            TenBit = c.ten,
            Pixels = new Afterscreen.Protocol.PixelSize(c.w, c.h),
            Bitrate = 20_000_000,
        };
        Console.WriteLine($"--- prove {c.name} {c.w}x{c.h} ---");
        using var enc = Afterscreen.Sender.Encode.MfH264Encoder.TryCreate(layer, 30, prefer, d3d);
        if (enc is null) { Console.WriteLine($"RESULT {c.name}: FAIL create"); continue; }
        var dxgi = enc.UsesDxgiInput || enc.BackendName.Contains("|dxgi", StringComparison.Ordinal);
        anyDxgi |= dxgi;
        anyOk = true;
        Console.WriteLine($"RESULT {c.name}: OK backend={enc.BackendName} UsesDxgiInput={enc.UsesDxgiInput}");
        // Extra: encode a few frames after create (prove already ran inside TryCreate).
        var bgra = new byte[c.w * c.h * 4];
        Array.Fill(bgra, (byte)64);
        var got = 0;
        for (var i = 0; i < 8; i++)
        {
            bgra[(i * 31) % bgra.Length] = (byte)(80 + i);
            if (enc.Encode(bgra, c.w, c.h, forceKeyframe: i == 0) is not null) got++;
        }
        Console.WriteLine($"  post-create encodes with output: {got}/8");
    }
    Console.WriteLine(anyDxgi
        ? "SUMMARY: at least one encoder used DXGI manager (texture samples in Encode when dxgi)."
        : "SUMMARY: no DXGI encoder — fell back to sysmem (texture input not selected).");
    return anyOk ? 0 : 1;
}

static int RunIdrProbe(int variant)
{
    // Dev experiment: does a given restart variant make the next frame an IDR on this encoder?
    var layer = new Afterscreen.Protocol.VideoLayer
    {
        Codec = string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_CODEC"), "hevc", StringComparison.OrdinalIgnoreCase) ? Afterscreen.Protocol.VideoCodec.hevc : Afterscreen.Protocol.VideoCodec.h264,
        Pixels = new Afterscreen.Protocol.PixelSize(1280, 720),
        Bitrate = int.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_PROBE_KBPS"), out var kb) ? kb * 1000 : 8_000_000,
    };
    var prefer = Afterscreen.Sender.Encode.GpuAdapters.Prefer();
    using var d3d = Afterscreen.Sender.Encode.D3dEncodeDevice.TryCreate(prefer);
    using var enc = Afterscreen.Sender.Encode.MfH264Encoder.TryCreate(layer, 30, prefer, d3d);
    if (enc is null) { Console.WriteLine("no encoder"); return 1; }
    Console.WriteLine($"encoder {enc.BackendName} variant={variant} hw={enc.IsHardware}");
    var bgra = new byte[1280 * 720 * 4];
    var rnd = new Random(1);
    var outs = new List<(int input, bool idr, int slice, int ps, int bytes)>();
    var restarts = new List<int>();
    var nulls = 0;
    for (var i = 0; i < 160; i++)
    {
        // moving noise so no scene-cut/IDR is triggered by content
        for (var k = 0; k < 60000; k++) bgra[rnd.Next(bgra.Length)] = (byte)(i * 5 + k);
        if (variant == 98 && i == 60) Console.WriteLine($"SetBitrate(1 Mbps) -> {enc.SetBitrate(1_000_000)}");
        var forceHere = variant == 99 && (i == 40 || i == 90 || i == 130);   // variant 99: ForceKeyFrame instead of a restart
        if (i == 40 || i == 90 || i == 130) { restarts.Add(outs.Count); if (variant != 99) enc.DebugRestart(variant); }
        var f = enc.Encode(bgra, 1280, 720, forceKeyframe: forceHere);
        if (f is null) { nulls++; Thread.Sleep(8); continue; }
        outs.Add((i, f.Keyframe, Afterscreen.Sender.Encode.MfH264Encoder.FirstSliceType(f.Avcc),
                  f.ParameterSets?.Length ?? 0, f.Avcc.Length));
    }
    Console.WriteLine($"outputs={outs.Count} nulls={nulls}  restarts before output #{string.Join(",#", restarts)}");
    if (variant == 98)
    {
        double Avg(int from, int to) { var l = outs.Where(o => !o.idr && o.input >= from && o.input < to).Select(o => (double)o.bytes).ToList(); return l.Count == 0 ? 0 : l.Average() / 1024; }
        Console.WriteLine($"avg P-frame KB: inputs 20-59 {Avg(20, 60):0.0} | 70-110 {Avg(70, 110):0.0} | 120-160 {Avg(120, 160):0.0}");
    }
    Console.WriteLine($"IDR outputs (#idx@input): {string.Join(" ", outs.Select((o, n) => (o, n)).Where(t => t.o.idr).Select(t => $"#{t.n}@{t.o.input}"))}");
    Console.WriteLine($"I-slice outputs:          {string.Join(" ", outs.Select((o, n) => (o, n)).Where(t => t.o.slice is 2 or 4 or 7 or 9).Select(t => $"#{t.n}@{t.o.input}"))}");
    foreach (var r in restarts)
        Console.WriteLine($"  after restart #{r}: " + string.Join(" ", outs.Skip(r).Take(5).Select(o => $"[in{o.input} idr={(o.idr ? 1 : 0)} sl={o.slice} ps={o.ps} {o.bytes / 1024}KB]")));
    return 0;
}

static int RunEncodeSmoke()
{
    Console.WriteLine("GPU adapters:");
    foreach (var a in Afterscreen.Sender.Encode.GpuAdapters.List())
        Console.WriteLine($"  {(a.IsHardware ? "HW" : "SW")} ven={a.VendorId:X4} {a.Description}");
    var prefer = Afterscreen.Sender.Encode.GpuAdapters.Prefer();
    Console.WriteLine($"prefer: {prefer?.Description}");

    var layer = new Afterscreen.Protocol.VideoLayer
    {
        Codec = Afterscreen.Protocol.VideoCodec.h264,
        Pixels = new Afterscreen.Protocol.PixelSize(1280, 720),
        Bitrate = 8_000_000,
    };
    using var d3d = Afterscreen.Sender.Encode.D3dEncodeDevice.TryCreate(prefer);
    Console.WriteLine(d3d is null ? "d3d: unavailable" : $"d3d: OK {d3d.Adapter.Description}");
    using var enc = Afterscreen.Sender.Encode.MfH264Encoder.TryCreate(layer, 30, prefer, d3d);
    if (enc is null)
    {
        Console.Error.WriteLine("MF H.264 encoder unavailable");
        return 1;
    }
    Console.WriteLine($"encoder: {enc.BackendName} hw={enc.IsHardware}");

    var bgra = new byte[1280 * 720 * 4];
    for (var i = 0; i < bgra.Length; i += 4) { bgra[i] = 40; bgra[i + 1] = 80; bgra[i + 2] = 160; bgra[i + 3] = 255; }
    Afterscreen.Sender.Encode.EncodedVideoFrame? frame = null;
    var produced = 0;
    var sw = System.Diagnostics.Stopwatch.StartNew();
    for (var i = 0; i < 60; i++)
    {
        // animate so the encoder emits more than one IDR
        bgra[(i * 16) % bgra.Length] = (byte)(i * 3);
        var f = enc.Encode(bgra, 1280, 720, forceKeyframe: i == 0);
        if (f is not null)
        {
            produced++;
            frame ??= f;
        }
    }
    sw.Stop();
    if (frame is null || produced == 0)
    {
        Console.Error.WriteLine("encode returned null");
        return 1;
    }
    Console.WriteLine($"first key={frame.Keyframe} avcc={frame.Avcc.Length} sets={frame.ParameterSets?.Length ?? 0}");
    Console.WriteLine($"produced {produced}/60 in {sw.ElapsedMilliseconds}ms (~{produced * 1000.0 / Math.Max(1, sw.ElapsedMilliseconds):F1} fps)");
    return 0;
}

static class SenderNative
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    /// <summary>DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4); best effort, older Windows keeps the default.</summary>
    public static void EnablePerMonitorDpiAwareness()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { /* pre-Windows 10 1703 */ }
    }
}
