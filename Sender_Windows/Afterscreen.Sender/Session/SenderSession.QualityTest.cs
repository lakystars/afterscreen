using System.Diagnostics;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Encode;

namespace Afterscreen.Sender.Session;

public sealed partial class SenderSession
{
    /// <summary>Mac "Test": stream the test pattern through the real pipeline at several sizes and report what the link and receiver keep up.</summary>
    public bool TestMode { get; set; }

    private const double TestFps = 60;

    /// <summary>
    /// Mac QualityTestRun: one stage per size (full motion, smallest first), then typical use at the session's size. Each stage
    /// sends its own Config, streams the pattern at the receiver's rate and averages the receiver's displayed fps after a
    /// warm-up. The receiver's picture must be showing first (its window opens during the first stage).
    /// </summary>
    private void RunQualityTest(Welcome welcome, double gbps, CancellationToken ct)
    {
        var report = new QualityTest.Report
        {
            Receiver = welcome.MarketingName.Length > 0 ? welcome.MarketingName : welcome.Name,
            Link = _linkKind,
            FrameRate = welcome.FrameRate,
        };
        using var gpuDev = D3dEncodeDevice.TryCreate();
        if (gpuDev is null) { End("Quality test unavailable: no hardware GPU"); return; }
        using var pattern = new GpuTestPattern(gpuDev);
        using var timer = HighResTimer.Begin();

        var panel = welcome.PanelPixels;
        var sizes = QualityTest.Stages(panel.Width > 0 ? panel : new PixelSize(3840, 2160)).ToList();
        var typical = EncodeServices.DefaultStream();
        var plan = sizes.Select(s => (Size: s, Typical: false)).Append((Size: typical, Typical: true)).ToList();
        report.Total = plan.Count;
        Snapshot.Quality = report;
        Publish();

        foreach (var (size, isTypical) in plan)
        {
            if (ct.IsCancellationRequested || Snapshot.Phase == SessionPhase.Ended) return;
            var stage = RunTestStage(welcome, gbps, gpuDev, pattern, timer, size, isTypical, report, ct);
            if (stage is null) return;
            if (isTypical) report.Typical = stage; else report.Stages.Add(stage);
            Publish();
        }
        report.Running = null;
        report.RunningTypical = false;
        report.Finished = true;
        Console.WriteLine("[quality-test] " + string.Join(", ", report.Stages.Select(s => $"{QualityTest.Label(s.Size)} {s.Size.Width}x{s.Size.Height} {s.Fps:0} fps {s.Gbps:0.00} Gb/s"))
            + (report.Typical is { } t ? $", typical {t.Size.Width}x{t.Size.Height} {t.Fps:0} fps" : ""));
        Publish();
        End("Quality test finished");
    }

    private QualityTest.Stage? RunTestStage(Welcome welcome, double gbps, D3dEncodeDevice gpuDev, GpuTestPattern pattern, HighResTimer timer,
        PixelSize size, bool typical, QualityTest.Report report, CancellationToken ct)
    {
        EncodePipeline pipeline;
        try { pipeline = EncodeServices.Create(welcome, _linkKind, gbps, null, size, test: true); }
        catch (Exception ex) { Console.WriteLine("[quality-test] pipeline failed: " + ex.Message); return new QualityTest.Stage { Size = size }; }
        using (pipeline)
        {
            var config = pipeline.Config;
            report.Running = size;
            report.RunningTypical = typical;
            report.Path = config.Path.ToString();
            Snapshot.Config = config;
            Snapshot.State = typical ? "Testing typical use" : $"Testing {QualityTest.Label(size)}";
            Publish();

            using var frame = new GpuFrame(gpuDev.Device, size.Width, size.Height, renderTarget: true);
            using var tile = GpuTileEncoder.TryCreate(gpuDev, size.Width, size.Height);
            if (tile is null) { Console.WriteLine("[quality-test] tile encoder unavailable"); return new QualityTest.Stage { Size = size }; }
            var geometry = new TileGeometry(size.Width, size.Height);
            var fps = Math.Max(1.0, config.FrameRate);
            var tileBytes = geometry.TilePixels * geometry.TilePixels;
            var settleBase = Math.Max(16, (int)(gbps * 1e9 / 8 / fps / tileBytes));
            tile.Bc7MotionLimit = (int)(gbps * 0.5e9 / 8 / fps / tileBytes);
            tile.Motion = TileMotion.Bc1;
            tile.SettleLimit = int.MaxValue;
            var video = pipeline.Video;
            var compPolicy = new CompressionPolicy(gbps, fps);
            int nVideo = 0, nTile = 0, nSkipQ = 0, nSkipV = 0, nTileNull = 0;
            var codec = config.Video?.Codec ?? VideoCodec.h264;
            var paramsSent = false;
            byte[]? heldTile = null;
            var heldSince = 0L;

            void SendVideo(EncodedVideoFrame v)
            {
                if (v.Keyframe && v.ParameterSets is { Length: > 0 })
                {
                    _conn?.Send(new Message(MessageType.VideoParams, 0, VideoWire.Params(codec, v.ParameterSets)));
                    if (!paramsSent) { paramsSent = true; tile.Motion = TileMotion.Video; tile.SettleLimit = settleBase; }
                }
                if (!paramsSent) return;
                _conn?.Send(new Message(MessageType.VideoFrame, 0, VideoWire.Frame(v.Keyframe, v.Avcc)));
                nVideo++;
            }
            void FlushHeld()
            {
                if (heldTile is not null) { _conn?.Send(new Message(MessageType.TileFrame, 0, heldTile)); nTile++; }
                heldTile = null;
            }

            _conn!.Send(JsonWire.Message(MessageType.Config, config));

            // Mac QualityTest.caption on the pattern (English test-card line).
            var step = report.Done + 1;
            var caption = QualityTest.Caption(size, _linkKind, step, report.Total, typical);
            pattern.SetCaption(caption, size.Height);
            Console.WriteLine($"[quality-test] caption: {caption}");

            // Clock: warm-up, then the measured seconds; starts once the receiver's picture shows (or after ShowWait)
            var sw = Stopwatch.StartNew();
            var samples = new List<double>();
            ReceiverStats? lastStats = null;
            var timing = false;
            double stageStart = 0, warmup = QualityTest.Warmup(size, gbps), measureStart = 0;
            var counterReset = false;
            var first = true;
            var last = -1;
            var queueWasFull = false;
            _conn.TakeBytesSent();

            while (!ct.IsCancellationRequested && Snapshot.Phase != SessionPhase.Ended)
            {
                var now = sw.Elapsed.TotalSeconds;

                // Receiver fps sample (the counter spans one second: one sample per Stats message)
                if (Snapshot.Receiver is { } rs && !ReferenceEquals(rs, lastStats))
                {
                    lastStats = rs;
                    var shown = rs.Shown ?? true;
                    if (IdrDiagnostics) Console.WriteLine($"[quality-test] receiver recv={rs.ReceivedFPS:0} shown={rs.DisplayedFPS:0} late={rs.LateFrames} upload={rs.UploadMs:0.0}ms cpu={rs.CpuPercent:0}% gpu={rs.GpuPercent:0}% visible={rs.Shown}");
                    if (!timing && shown) { timing = true; stageStart = now + 0.5; }
                    else if (timing && shown && now - stageStart >= warmup) samples.Add(rs.DisplayedFPS);
                }
                if (!timing && now >= QualityTest.ShowWait) { timing = true; stageStart = now; }
                if (timing && !counterReset && now - stageStart >= warmup) { counterReset = true; measureStart = now; _conn.TakeBytesSent(); }
                if (timing && now - stageStart >= warmup + QualityTest.MeasureSeconds) break;

                // Finish a held tile frame once its video output arrived
                if (video is { InputInFlight: true })
                {
                    var late = video.PollOutput(0);
                    if (late is not null) { SendVideo(late); FlushHeld(); }
                    else if (heldTile is not null && Environment.TickCount64 - heldSince > 400) FlushHeld();
                }
                else if (heldTile is not null) FlushHeld();

                // Pattern frames at the receiver's rate, indexed from the clock: a stalled tick skips, never repeats
                var index = Math.Max(last + 1, (int)(now * fps + 0.25));
                if (index == last || (int)(now * fps + 0.25) < index) { timer.Sleep(1); continue; }
                if (_conn.QueuedFrames >= 2) { queueWasFull = true; nSkipQ++; timer.Sleep(1); continue; }
                if (video is { InputInFlight: true }) { nSkipV++; timer.Sleep(1); continue; }
                last = index;

                pattern.Render(frame, index, typical);
                var congested = queueWasFull;
                queueWasFull = false;
                var enc = tile.Encode(frame, forceAll: first, dirty: null, Environment.TickCount64 / 1000.0, congested, start: first);
                first = false;
                byte[]? payload = null;
                if (enc is not null)
                {
                    var mode = compPolicy.Next(enc.DataLength, congested);
                    payload = enc.BuildPayload(_frameIndex++, geometry, mode, out var lz4In, out var lz4Out);
                    if (mode != TileCompression.None) compPolicy.Record(lz4In, lz4Out);
                }
                var hold = false;
                var accepted = false;
                if (video is MfH264Encoder mf && tile.LossyTiles > 0)
                {
                    EncodedVideoFrame? v = null;
                    try { v = mf.EncodeGpu(gpuDev, frame, forceKeyframe: !paramsSent); }
                    catch (Exception ex) { Console.WriteLine("[quality-test] video: " + ex.Message); video = null; }
                    if (v is not null) { SendVideo(v); accepted = true; }
                    else if (mf.InputInFlight) { hold = true; accepted = true; }
                }
                if (payload is null && accepted)
                    payload = TileFrameWire.Empty(_frameIndex++, geometry);      // present the video (the receiver shows pictures on tile frames)
                if (payload is not null)
                {
                    if (hold) { heldTile = payload; heldSince = Environment.TickCount64; }
                    else { _conn.Send(new Message(MessageType.TileFrame, 0, payload)); nTile++; }
                }
                else nTileNull++;
            }
            FlushHeld();
            Console.WriteLine($"[quality-test] {(typical ? "typical" : QualityTest.Label(size))}: video={nVideo} tile={nTile} tileNull={nTileNull} skipQueue={nSkipQ} skipVideo={nSkipV} samples=[{string.Join(",", samples.Select(x => x.ToString("0")))}] lossy={tile.LossyTiles} path={config.Path}");

            var seconds = Math.Max(0.5, sw.Elapsed.TotalSeconds - (counterReset ? measureStart : stageStart));
            var bytes = _conn.TakeBytesSent();
            return new QualityTest.Stage
            {
                Size = size,
                Fps = samples.Count == 0 ? 0 : samples.Average(),
                Gbps = bytes * 8.0 / Math.Min(seconds, QualityTest.MeasureSeconds) / 1e9,
                Motion = config.Video?.Pixels,
                VideoBitrate = config.Video?.Bitrate,
            };
        }
    }
}
