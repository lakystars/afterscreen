using System.Diagnostics;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Encode;
using Afterscreen.Transport;

namespace Afterscreen.Sender.Session;

/// <summary>
/// The Mac Sender's frame pipeline (<c>FrameStreamer.process</c> / <c>drain</c> / <c>refine</c>) on the GPU:
/// capture keeps the picture in a GPU texture, <see cref="GpuTileEncoder"/> (port of <c>TileEncoder</c>) decides
/// per tile between BC7, BC1 and the video layer, the video encoder runs only while tiles are lossy, and a video
/// output is sent before the tile frame that masks its tiles (the Mac outbox, one entry deep because the QSV
/// encoder takes one input at a time). Falls back to the CPU loop when the GPU path is unavailable.
/// </summary>
public sealed partial class SenderSession
{
    private GpuTileEncoder? _macTile;
    private double _tileMsSum;
    private int _tileN;

    private static bool MacTilesEnabled =>
        !string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_TILEENC"), "legacy", StringComparison.OrdinalIgnoreCase);

    private static double NowSeconds() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    /// <summary>Starts DXGI capture (on the shared GPU device when possible) and the cursor channel.</summary>
    private DxgiCapture? StartCapture(StreamConfig config, D3dEncodeDevice? shared)
    {
        try
        {
            var capture = new DxgiCapture(config.StreamPixels.Width, config.StreamPixels.Height, shared);
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
            return capture;
        }
        catch (Exception ex)
        {
            Snapshot.State = $"Streaming (no capture: {ex.Message})";
            Publish();
            return null;
        }
    }

    private void StreamLoopMac(EncodePipeline pipeline, CancellationToken ct)
    {
        var config = pipeline.Config;
        var width = config.StreamPixels.Width;
        var height = config.StreamPixels.Height;

        // Capture + tiles on one device. MF/QSV historically used pipeline.D3d alone (sharing with BC7 tiles
        // grew WS); Phase B rebinds MF DXGI onto this same gpuDev so VideoProcessor can feed textures.
        var gpuDev = EnableCapture ? D3dEncodeDevice.TryCreate(pipeline.Adapter) : null;
        DxgiCapture? capture = null;
        GpuTileEncoder? tile = null;
        if (gpuDev is not null)
        {
            capture = StartCapture(config, gpuDev);
            if (capture is { HasGpuFrame: true })
                tile = GpuTileEncoder.TryCreate(gpuDev, width, height);
        }
        if (capture is null || tile is null || capture.Gpu is null)
        {
            Console.WriteLine("[gpu-tiles] GPU picture unavailable (needs a hardware adapter shared with the monitor and a stream the size of the monitor); using the CPU tile path");
            tile?.Dispose();
            capture?.Dispose();
            gpuDev?.Dispose();
            StreamLoop(pipeline, ct);
            return;
        }

        // Phase B: one MF create on gpuDev (EncodeServices deferred video when ZEROCOPY). Avoid create+dispose residue.
        if (VideoZeroCopy.Wanted && gpuDev is not null && config.Video is { } zcLayer)
        {
            try
            {
                var bound = MfH264Encoder.TryCreate(zcLayer, config.FrameRate, pipeline.Adapter, gpuDev, preferDxgi: true);
                if (bound is MfH264Encoder { IsHardware: true, UsesDxgiInput: true })
                {
                    pipeline.ReplaceVideo(bound);
                    Console.WriteLine("[zerocopy] MF DXGI on capture/tile device");
                }
                else
                {
                    bound?.Dispose();
                    var fallback = MfH264Encoder.TryCreate(zcLayer, config.FrameRate, pipeline.Adapter, pipeline.D3d);
                    if (fallback is { IsHardware: true })
                    {
                        pipeline.ReplaceVideo(fallback);
                        Console.WriteLine("[zerocopy] DXGI on gpuDev failed — pipeline.D3d encoder (A′ if manager set)");
                    }
                    else
                    {
                        fallback?.Dispose();
                        Console.WriteLine("[zerocopy] no hardware video encoder");
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("[zerocopy] MF bind error: " + ex.Message);
            }
        }

        // Dispose pipeline (video on gpuDev) before gpuDev (ownership order).
        using (gpuDev)
        using (var timer = HighResTimer.Begin())
        using (tile)
        using (capture)
        using (pipeline)
        {
            var geometry = new TileGeometry(width, height);
            var video = pipeline.Video;
            _videoRef = video;
            _tilesRef = null;
            _macTile = tile;
            var gate = new FrameGate<CapturedFrame>(1000.0 / Math.Max(1, config.FrameRate) - 2);

            // Mac FrameStreamer.apply: budgets from the measured link (tiles per frame).
            var linkGbps = Snapshot.CapacityGbps ?? 0;
            var tileBytes = geometry.TilePixels * geometry.TilePixels;   // BC7: 1 byte per pixel
            var fps = Math.Max(1.0, config.FrameRate);
            var settleBase = Math.Max(16, (int)(linkGbps * 1e9 / 8 / fps / tileBytes));
            tile.Bc7MotionLimit = (int)(linkGbps * 0.5e9 / 8 / fps / tileBytes);
            tile.Motion = TileMotion.Bc1;               // until the video layer has delivered its first IDR + parameter sets
            tile.SettleLimit = int.MaxValue;

            var codec = config.Video?.Codec ?? VideoCodec.h264;
            var videoReady = false;
            var videoParamsSent = false;
            var opened = false;
            var queueWasFull = false;
            var compPolicy = new CompressionPolicy(Snapshot.CapacityGbps, fps);   // Mac CompressionPolicy
            var forceLz4 = Environment.GetEnvironmentVariable("AFTERSCREEN_LZ4") == "1";

            // Mac TilePacker + CompressionPolicy: LZ4 when the frame would not fit the link with headroom or the link is
            // congested; otherwise stored. Returns the payload and the raw (uncompressed) tile bytes it carries.
            (byte[] payload, int raw) Pack(EncodedGpuFrame f, bool congested)
            {
                var mode = compPolicy.Next(f.DataLength, congested);
                if (forceLz4 && mode == TileCompression.None) mode = TileCompression.All;   // AFTERSCREEN_LZ4=1: exercise the receiver path
                var bytes = f.BuildPayload(_frameIndex++, geometry, mode, out var lz4In, out var lz4Out);
                if (mode != TileCompression.None)
                    compPolicy.Record(lz4In, lz4Out);
                return (bytes, f.DataLength);
            }
            // Mac FrameStreamer.outbox: frames leave in capture order; one awaiting its video output holds back later
            // ones. Pipelined (async encoder): the next frame's tiles and YUV are prepared while the encoder works on
            // the previous one, and handed over when its output is collected - at most one in the encoder, one ready.
            var outbox = new Queue<VideoOutgoing>();
            var pipelined = video is MfH264Encoder { CanSubmitWithoutWait: true }
                && Environment.GetEnvironmentVariable("AFTERSCREEN_GPUVIDEO") != "0"
                && Environment.GetEnvironmentVariable("AFTERSCREEN_VIDEO_PIPELINE") != "0";
            var lastRefineMs = 0L;
            Console.WriteLine($"[video] {(pipelined ? "pipelined: prepares the next frame while one encodes" : "one frame at a time")}");

            // Mac RateControl (FrameStreamer.sampleLink / adjustRate): video bitrate backs off while the link queues and
            // recovers slowly. Four socket samples a second (TCP_INFO), one decision a second. The Intel encoder cannot
            // change its bitrate while running (ICodecAPI MeanBitRate is accepted but ignored; flush/renegotiation do not
            // help either), so a decision is applied by building a fresh encoder at the new bitrate: its first
            // frame is an IDR with parameter sets, and only changes of 25% or more are applied to keep rebuilds rare.
            var rateStart = config.Video?.Bitrate ?? 0;
            var rate = video is not null && rateStart > 0 && Environment.GetEnvironmentVariable("AFTERSCREEN_RATE") != "0"
                ? new RateControl(rateStart, fps) : null;
            var rateDemo = Environment.GetEnvironmentVariable("AFTERSCREEN_RATE_DEMO") == "1";   // dev: cut to 1/4 for 20 s
            var demoStartMs = Environment.TickCount64;
            var wantedBitrate = rateStart;
            var appliedBitrate = rateStart;
            var rateTicks = 0;
            var rateOffered = 0;
            var rateFullFrame = false;
            long lastTcpOut = 0, lastTcpRetrans = 0, lastTcpAt = 0, leastBuffered = long.MaxValue, leastWindow = long.MaxValue;
            var rtts = new Queue<double>();
            IVideoEncoder? extraVideo = null;                // encoders this loop built (the pipeline disposes its own)
            using var extraScope = new ActionDisposable(() => extraVideo?.Dispose());
            Snapshot.VideoBitrate = rateStart;
            Snapshot.VideoStartBitrate = rateStart;
            var needVideoKey = false;

            void SampleLink(long nowMs)
            {
                if (_conn?.GetTcpInfo() is not { } tcp) return;
                if (lastTcpAt == 0) { lastTcpOut = tcp.BytesOut; lastTcpRetrans = tcp.BytesRetrans; lastTcpAt = nowMs; }
                // Socket and app queue: the limit moves backlog here
                var buffered = tcp.BytesInFlight + _conn.QueuedBytes;
                leastBuffered = Math.Min(leastBuffered, buffered);
                leastWindow = Math.Min(leastWindow, tcp.SendWindow);
                if (++rateTicks % 4 != 0) return;

                var dt = (nowMs - lastTcpAt) / 1000.0;
                var sentBps = dt > 0 && tcp.BytesOut >= lastTcpOut ? (tcp.BytesOut - lastTcpOut) * 8 / dt : 0;
                var dOut = tcp.BytesOut - lastTcpOut;
                var dRe = tcp.BytesRetrans - lastTcpRetrans;
                _retransmitPercent = dOut > 0 && dRe >= 0 ? Math.Min(100, dRe * 100.0 / dOut) : 0;
                lastTcpOut = tcp.BytesOut; lastTcpRetrans = tcp.BytesRetrans; lastTcpAt = nowMs;
                // Latency and its variation for the stats (jitter: mean deviation of the last 10 seconds)
                _rttMs = tcp.RttMs > 0 ? tcp.RttMs : null;
                if (tcp.RttMs > 0)
                {
                    rtts.Enqueue(tcp.RttMs);
                    while (rtts.Count > 10) rtts.Dequeue();
                    var mean = rtts.Average();
                    _jitterMs = rtts.Average(r => Math.Abs(r - mean));
                }

                var bufferedLeast = leastBuffered == long.MaxValue ? 0 : (int)Math.Min(int.MaxValue, leastBuffered);
                var window = leastWindow;
                leastBuffered = long.MaxValue; leastWindow = long.MaxValue;
                var sample = new RateControl.Sample
                {
                    Frames = rateOffered,
                    SentBps = sentBps,
                    RttMs = tcp.RttMs,
                    Buffered = bufferedLeast,
                    ReceiverLimited = window < RateControl.StalledWindow,
                    FullFrame = rateFullFrame,
                };
                rateOffered = 0;
                rateFullFrame = false;
                if (rate is null) return;
                var before = rate.Bitrate;
                if (rateDemo)
                {
                    var t = (nowMs - demoStartMs) / 1000;
                    var demo = t is >= 20 and < 40 ? rateStart / 4 : rateStart;
                    if (demo != wantedBitrate) { wantedBitrate = demo; Console.WriteLine($"[rate] demo target {demo / 1_000_000} Mbps"); }
                    return;
                }
                if (rate.Update(sample) is { } next)
                {
                    wantedBitrate = next;
                    Console.WriteLine($"[rate] video bitrate {before / 1_000_000} -> {next / 1_000_000} Mbps (rtt {tcp.RttMs:0.0} ms, buffered {bufferedLeast / 1024} KB, sent {sentBps / 1e6:0} Mbps)");
                }
            }

            // Applies the wanted bitrate when it differs enough: the fresh encoder is built on a background thread (building
            // takes 1-3 s: proving frames plus the unfed instance) and swapped in between frames.
            Task<IVideoEncoder?>? rebuild = null;
            var rebuildBitrate = 0;
            var rebuildAt = 0L;
            long lastRebuildDoneMs = 0;
            static long nowTick() => Environment.TickCount64;
            void ApplyRate()
            {
                if (rate is null || video is null) return;
                if (rebuild is null)
                {
                    var diff = Math.Abs(wantedBitrate - appliedBitrate);
                    if (diff < appliedBitrate * 0.25 && !(wantedBitrate == rateStart && appliedBitrate != rateStart)) return;
                    // Opt-in live paths (QSV usually ignores MeanBitRate). Default stays rebuild.
                    // AFTERSCREEN_RATE_LIVE=1 → SetBitrate; AFTERSCREEN_RATE_QP=1 → CommonQuality from bitrate ratio.
                    if (Environment.GetEnvironmentVariable("AFTERSCREEN_RATE_LIVE") == "1"
                        && video.SetBitrate(wantedBitrate))
                    {
                        appliedBitrate = wantedBitrate;
                        Snapshot.VideoBitrate = appliedBitrate;
                        if (videoReady) tile.SettleLimit = Math.Max(16, (int)((long)settleBase * appliedBitrate / Math.Max(1, rateStart)));
                        Console.WriteLine($"[rate] live SetBitrate {appliedBitrate / 1_000_000} Mbps (no rebuild)");
                        return;
                    }
                    if (Environment.GetEnvironmentVariable("AFTERSCREEN_RATE_QP") == "1")
                    {
                        var q = (int)Math.Clamp(100.0 * wantedBitrate / Math.Max(1, rateStart), 20, 100);
                        if (video.SetQuality(q))
                        {
                            appliedBitrate = wantedBitrate;
                            Snapshot.VideoBitrate = appliedBitrate;
                            if (videoReady) tile.SettleLimit = Math.Max(16, (int)((long)settleBase * appliedBitrate / Math.Max(1, rateStart)));
                            Console.WriteLine($"[rate] live Quality={q} for {appliedBitrate / 1_000_000} Mbps (no rebuild)");
                            return;
                        }
                    }
                    // Each rebuild stalls the picture for a moment and leaves ~300 MB of driver memory behind: not more
                    // often than every 10 s
                    if (nowTick() - lastRebuildDoneMs < 10_000) return;
                    var cfg = config.Video!;
                    var layer = new VideoLayer { Codec = cfg.Codec, Pixels = cfg.Pixels, Bitrate = wantedBitrate, TenBit = cfg.TenBit };
                    rebuildBitrate = wantedBitrate;
                    rebuildAt = Stopwatch.GetTimestamp();
                    var adapter = pipeline.Adapter;
                    // Same device as the live encoder (gpuDev when zero-copy DXGI is active).
                    var zcLive = VideoZeroCopy.Wanted && video is MfH264Encoder { UsesDxgiInput: true };
                    var d3d = zcLive ? gpuDev : pipeline.D3d;
                    var preferDxgi = zcLive;
                    rebuild = Task.Run<IVideoEncoder?>(() =>
                    {
                        try { return MfH264Encoder.TryCreate(layer, fps, adapter, d3d, preferDxgi: preferDxgi); }
                        catch (Exception ex) { Console.WriteLine("[rate] rebuild failed: " + ex.Message); return null; }
                    });
                    return;
                }
                // Not while an output is owed: it would be lost with the old encoder. A prepared frame lives in the old
                // encoder's input sample, so its tile frame goes without it (the new encoder opens with an IDR anyway).
                if (!rebuild.IsCompleted || video.InputInFlight || outbox.Any(e => e.Submitted && e.WaitsVideo)) return;
                var fresh = rebuild.Result;
                rebuild = null;
                appliedBitrate = rebuildBitrate;                      // also when it failed: do not retry every second
                lastRebuildDoneMs = nowTick();
                if (fresh is null || !fresh.IsHardware)
                {
                    fresh?.Dispose();
                    return;
                }
                foreach (var e in outbox)
                {
                    if (!e.Prepared) continue;
                    e.Prepared = false;
                    e.WaitsVideo = false;
                }
                Drain();
                var old = video;
                video = fresh;
                if (extraVideo is not null && !ReferenceEquals(extraVideo, old)) extraVideo.Dispose();
                extraVideo = fresh;
                old.Dispose();
                _videoRef = fresh;
                videoParamsSent = false;                              // the fresh encoder opens with an IDR + parameter sets
                Snapshot.VideoBitrate = appliedBitrate;
                if (videoReady) tile.SettleLimit = Math.Max(16, (int)((long)settleBase * appliedBitrate / Math.Max(1, rateStart)));
                Console.WriteLine($"[rate] video encoder now {appliedBitrate / 1_000_000} Mbps (built in {Stopwatch.GetElapsedTime(rebuildAt).TotalMilliseconds:0} ms in the background)");
            }

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
            var statTiles = new bool[geometry.TileCount];   // only its length is used (tile count for the HUD)
            _wantKeyframe = false;

            // Mac Capture.onFrame = FrameStreamer.offer: capture runs on its own thread and only replaces the gate's
            // frame (merging the dirty regions of one it drops); this loop is the pump and is woken by each offer.
            var tally = new CaptureTally();
            using var captureWake = new AutoResetEvent(false);
            capture.StartThread(offered =>
            {
                Interlocked.Increment(ref tally.Frames);
                _capIv.Note();
                gate.Offer(offered, Environment.TickCount64,
                    static (dropped, newer) => newer.Dirty = CapturedFrame.Merge(dropped.Dirty, newer.Dirty),
                    out var droppedOpen);
                if (droppedOpen) Interlocked.Increment(ref tally.Dropped);
                captureWake.Set();
            });
            using var stopCapture = new ActionDisposable(capture.StopThread);   // before captureWake goes

            void SendTile(byte[] payload, int raw, bool refinement = false)
            {
                // Mac FrameStreamer.send: refinements set TileFlags.refinement (flashBlocks on receiver).
                var flags = refinement ? TileFlags.Refinement : (byte)0;
                _conn?.Send(new Message(MessageType.TileFrame, flags, payload));
                Snapshot.FramesSent++;
                sentFrames++;
                wireTileBytes += payload.Length;
                rawTileBytes += raw;
            }

            void SendVideo(EncodedVideoFrame v)
            {
                if (v.Keyframe && v.ParameterSets is { Length: > 0 })
                {
                    _conn?.Send(new Message(MessageType.VideoParams, 0, VideoWire.Params(codec, v.ParameterSets)));
                    videoParamsSent = true;
                    if (!videoReady)
                    {
                        // Mac: .video motion with the settle budget once the video layer exists.
                        videoReady = true;
                        tile.Motion = TileMotion.Video;
                        tile.SettleLimit = settleBase;
                    }
                }
                if (!videoParamsSent)
                    return;                              // a P frame the receiver cannot decode yet
                _conn?.Send(new Message(MessageType.VideoFrame, 0, VideoWire.Frame(v.Keyframe, v.Avcc)));
                _vidIv.Note();
                Snapshot.FramesSent++;
                sentFrames++;
            }

            // Mac drain: sends ready frames in order; the video picture went out before the tile frame presenting it.
            void Drain()
            {
                while (outbox.Count > 0 && !outbox.Peek().WaitsVideo)
                {
                    var e = outbox.Dequeue();
                    if (e.Tile is not null) SendTile(e.Tile, e.Raw);
                }
            }

            // Nothing more to wait for (encoder gone or stuck): queued tile frames go without their video.
            void ReleaseOutbox()
            {
                foreach (var e in outbox)
                {
                    e.WaitsVideo = false;
                    e.Prepared = false;
                }
                Drain();
            }

            // Encoder outputs arrive in submission order: each completes the oldest submitted entry.
            void VideoDone(EncodedVideoFrame v)
            {
                SendVideo(v);
                foreach (var e in outbox)
                {
                    if (!e.Submitted || !e.WaitsVideo) continue;
                    e.WaitsVideo = false;
                    break;
                }
                Drain();
            }

            // Mac fallBackToBC1: the video layer stopped working; motion continues as BC1 and lossy tiles settle.
            void FallBackToBc1(string why)
            {
                Console.WriteLine($"[video] {why} -> BC1");
                video = null;
                videoReady = false;
                tile.Motion = TileMotion.Bc1;
                tile.SettleLimit = settleBase;
                ReleaseOutbox();
            }

            // Hands the prepared frame to the encoder once it is free.
            void SubmitPrepared(long nowMs)
            {
                if (video is not MfH264Encoder mf || mf.InputInFlight) return;
                VideoOutgoing? next = null;
                foreach (var e in outbox)
                    if (e.Prepared) { next = e; break; }
                if (next is null) return;
                bool taken;
                try { taken = mf.SubmitPrepared(forceKeyframe: next.Key || !videoParamsSent); }
                catch (Exception ex) { FallBackToBc1("encode: " + ex.Message); return; }
                next.Prepared = false;
                if (taken)
                {
                    next.Submitted = true;
                    next.Since = nowMs;
                }
                else
                {
                    next.WaitsVideo = false;            // not taken: its tile frame goes without a new picture
                    Drain();
                }
            }

            // Collects a finished output (no waiting when budgetMs is 0), then feeds the encoder the prepared frame.
            void PumpVideo(long nowMs, int budgetMs)
            {
                if (video is MfH264Encoder { HasOutputPending: true } || video is { InputInFlight: true })
                {
                    var v = video.PollOutput(budgetMs);
                    if (v is not null)
                        VideoDone(v);
                }
                // Never hold a tile frame behind a stuck encoder, nor behind one that owes nothing any more
                var owing = video is MfH264Encoder { HasOutputPending: true } || video is { InputInFlight: true };
                foreach (var e in outbox)
                    if (e is { Submitted: true, WaitsVideo: true } && (!owing || nowMs - e.Since > 400))
                        e.WaitsVideo = false;
                Drain();
                if (video is { InputInFlight: false })
                {
                    ApplyRate();
                    SubmitPrepared(nowMs);
                }
            }

            while (!ct.IsCancellationRequested && Snapshot.Phase == SessionPhase.Streaming)
            {
                try
                {
                    if (_conn is null || _conn.IsClosed)
                    {
                        End("closed: stream peer");
                        break;
                    }

                    var newFrames = Interlocked.Exchange(ref tally.Frames, 0);
                    captureFrames += newFrames;
                    rateOffered += newFrames;
                    droppedFrames += Interlocked.Exchange(ref tally.Dropped, 0);

                    var nowMs = Environment.TickCount64;
                    SampleLink(nowMs);
                    ApplyRate();
                    if (pipelined)
                        PumpVideo(nowMs, 0);
                    var qf = _conn.QueuedFrames;
                    var qm = _conn.QueuedNormalMessages;
                    if (qf >= 2) queueWasFull = true;       // Mac pump: the link held a frame back
                    // Mac pump: inFlight < 2. Pipelined: one frame in the encoder and one prepared; otherwise no new
                    // frame while the encoder holds one.
                    var videoBusy = pipelined
                        ? outbox.Count >= 2 || outbox.Any(e => e.Prepared)
                        : video is { InputInFlight: true };
                    var busy = qf >= 2 || qm >= 4 || videoBusy;

                    var frame = gate.Take(nowMs, busy);
                    if (frame is null)
                    {
                        // A late video output completes the outbox entry: video first, then its tile frame.
                        // Polled whenever an input is in flight - the encoder only clears that state from here.
                        if (!pipelined)
                            PumpVideo(nowMs, video is { InputInFlight: true } ? 20 : 0);

                        // Mac refine(): lossy tiles that have been still for settleDelay get their BC7, only with
                        // nothing in flight and room on the connection (its frames are not droppable).
                        if (outbox.Count == 0 && qf < 2 && qm < 4 && tile.LossyTiles > 0 && nowMs - lastRefineMs >= 16)
                        {
                            lastRefineMs = nowMs;
                            var t0 = Stopwatch.GetTimestamp();
                            var refined = tile.Refine(capture.Gpu!, NowSeconds());
                            _fmtBc7 += tile.LastFmtBc7;
                            _fmtBc1 += tile.LastFmtBc1;
                            _fmtVideo += tile.LastFmtVideo;
                            if (refined is not null)
                            {
                                var (payload, raw) = Pack(refined, false);
                                SendTile(payload, raw, refinement: true);
                                if (IdrDiagnostics)
                                    Console.WriteLine($"[settle] tiles={refined.TileCount} bytes={payload.Length} enc={Stopwatch.GetElapsedTime(t0).TotalMilliseconds:0.0}ms");
                            }
                        }

                        var delay = gate.DelayMs(Environment.TickCount64);
                        var wait = gate.Pending is not null && !busy
                            ? (int)Math.Min(Math.Max(1, delay), 4)
                            : (int)Math.Min(Math.Max(1, delay), 8);
                        // The encoder reports by event, not callback: poll its output every millisecond
                        if (pipelined && video is MfH264Encoder { HasOutputPending: true })
                            wait = 1;
                        if (busy && !videoBusy)
                            Snapshot.State = $"Streaming (backpressure qf={qf} qm={qm})";
                        timer.Sleep(wait, captureWake);
                        FlushSenderStats(ref statsAt, ref encodeMsSum, ref encodedFrames, ref dirtyTilesSum, ref dirtySamples,
                            ref rawTileBytes, ref wireTileBytes, ref sentFrames, ref captureFrames, ref droppedFrames,
                            statTiles, config);
                        continue;
                    }

                    // Mac FrameStreamer.process
                    var encT0 = Stopwatch.GetTimestamp();
                    var forceAll = !opened || _wantKeyframe;     // first frame, or the receiver asked for a keyframe
                    if (_wantKeyframe) needVideoKey = true;      // ...and the video layer answers with an IDR (ForceKeyFrame)
                    var start = !opened;
                    _wantKeyframe = false;
                    opened = true;
                    var outFrame = tile.Encode(frame.Gpu!, forceAll, frame.Dirty, NowSeconds(), queueWasFull, start);
                    _tileMsSum += Stopwatch.GetElapsedTime(encT0).TotalMilliseconds;
                    _tileN++;
                    var congestedNow = queueWasFull;
                    queueWasFull = false;
                    dirtyTilesSum += tile.ChangedTiles;
                    dirtySamples++;
                    _clsStill += tile.LastStill;
                    _clsMoving += tile.LastMoving;
                    _fmtBc7 += tile.LastFmtBc7;
                    _fmtBc1 += tile.LastFmtBc1;
                    _fmtVideo += tile.LastFmtVideo;
                    byte[]? tilePayload = null;
                    var tileRaw = 0;
                    if (outFrame is not null)
                    {
                        (tilePayload, tileRaw) = Pack(outFrame, congestedNow);
                        if (outFrame.TileCount * 10 >= geometry.TileCount * 9) rateFullFrame = true;   // a whole-screen burst is not a queue
                    }

                    var holdForVideo = false;
                    var videoAccepted = false;
                    VideoOutgoing? prepared = null;
                    if (pipelined && video is MfH264Encoder { CanSubmitWithoutWait: true } pmf && tile.LossyTiles > 0)
                    {
                        // Converted now into the encoder's free input sample (also while the previous frame encodes),
                        // handed over by SubmitPrepared
                        try
                        {
                            pmf.ConvertGpu(gpuDev!, frame.Gpu!);
                            prepared = new VideoOutgoing { Prepared = true, Key = needVideoKey, WaitsVideo = true, Since = nowMs };
                            videoAccepted = true;
                        }
                        catch (Exception ex)
                        {
                            FallBackToBc1("encode: " + ex.Message);
                        }
                        needVideoKey = false;
                    }
                    else if (video is not null && tile.LossyTiles > 0 && !video.InputInFlight)
                    {
                        EncodedVideoFrame? v = null;
                        try
                        {
                            // GPU scale + YUV convert from the GPU picture when possible (no CPU readback of the picture).
                            v = video is MfH264Encoder mf && mf.CanEncodeGpu && Environment.GetEnvironmentVariable("AFTERSCREEN_GPUVIDEO") != "0"
                                ? mf.EncodeGpu(gpuDev!, frame.Gpu!, forceKeyframe: !videoParamsSent || needVideoKey)
                                : video.Encode(frame.Bgra, frame.Width, frame.Height, forceKeyframe: !videoParamsSent || needVideoKey);
                        }
                        catch (Exception ex)
                        {
                            FallBackToBc1("encode: " + ex.Message);
                        }
                        needVideoKey = false;
                        if (v is not null)
                        {
                            SendVideo(v);
                            videoAccepted = true;
                        }
                        else if (video is { InputInFlight: true })
                        {
                            // Accepted, output not there yet: hold the tile frame behind it (Mac outbox).
                            holdForVideo = true;
                            videoAccepted = true;
                        }
                    }
                    // The receiver shows a picture when a tile frame arrives: a video frame with no tile data of its own is
                    // paired with an empty tile frame ("presents only"), as the Mac does. Without it, a screen that is all
                    // video (full-screen playback, the quality test's full motion) showed no new picture at all.
                    if (tilePayload is null && videoAccepted)
                    {
                        tilePayload = TileFrameWire.Empty(_frameIndex++, geometry);
                        tileRaw = 0;
                    }

                    if (prepared is not null)
                    {
                        prepared.Tile = tilePayload;
                        prepared.Raw = tileRaw;
                        outbox.Enqueue(prepared);
                        SubmitPrepared(nowMs);
                    }
                    else if (holdForVideo)
                    {
                        // Accepted, output not there yet: the tile frame (or nothing, video-only) waits behind it
                        outbox.Enqueue(new VideoOutgoing { Tile = tilePayload, Raw = tileRaw, WaitsVideo = true, Submitted = true, Since = nowMs });
                    }
                    else if (tilePayload is not null)
                    {
                        outbox.Enqueue(new VideoOutgoing { Tile = tilePayload, Raw = tileRaw });
                    }
                    Drain();

                    Snapshot.State = $"Streaming (mac tiles lossy={tile.LossyTiles} changed={tile.ChangedTiles}{(videoReady ? " video" : "")})";
                    var encMs = Stopwatch.GetElapsedTime(encT0).TotalMilliseconds;
                    encodeMsSum += encMs;
                    encodedFrames++;
                    _gpuMeter.AddBusyMs(encMs);

                    FlushSenderStats(ref statsAt, ref encodeMsSum, ref encodedFrames, ref dirtyTilesSum, ref dirtySamples,
                        ref rawTileBytes, ref wireTileBytes, ref sentFrames, ref captureFrames, ref droppedFrames,
                        statTiles, config);
                    if (Snapshot.FramesSent > 0 && Snapshot.FramesSent % 30 == 0)
                        Publish();
                }
                catch (Exception ex)
                {
                    End("stream: " + ex.Message);
                    break;
                }
            }
            _macTile = null;
            if (rebuild is not null)
            {
                try
                {
                    if (!rebuild.Wait(TimeSpan.FromSeconds(8)))
                        Console.WriteLine("[rate] rebuild still running at stream end — abandoning wait");
                    else
                        rebuild.Result?.Dispose();
                }
                catch (Exception ex) { Console.WriteLine("[rate] rebuild cleanup: " + ex.Message); }
                rebuild = null;
            }
        }
    }
}

/// <summary>Mac <c>FrameStreamer.Outgoing</c>: a tile frame and the video picture it waits for.</summary>
internal sealed class VideoOutgoing
{
    public byte[]? Tile;
    public int Raw;
    /// <summary>Held until its video output went out (or the wait was given up).</summary>
    public bool WaitsVideo;
    /// <summary>In the encoder; its output completes this entry.</summary>
    public bool Submitted;
    /// <summary>Its picture is the encoder's prepared input, not handed over yet.</summary>
    public bool Prepared;
    public bool Key;
    public long Since;
}

/// <summary>Frames the capture thread handed over since the stream loop last read them.</summary>
internal sealed class CaptureTally
{
    public int Frames;
    public int Dropped;
}

/// <summary>Runs an action when disposed (a <c>using</c> scope for cleanup of locals).</summary>
internal sealed class ActionDisposable : IDisposable
{
    private readonly Action _action;
    public ActionDisposable(Action action) => _action = action;
    public void Dispose() => _action();
}
