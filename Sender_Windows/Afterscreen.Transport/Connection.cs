using System.Collections.Concurrent;
using System.Net.Sockets;
using Afterscreen.Protocol;

namespace Afterscreen.Transport;

/// <summary>
/// Mac Connection analogue: reads on a background thread, writes on a serial queue.
/// <see cref="QueuedFrames"/> caps the hybrid path (Mac: inFlight &lt; 2).
/// </summary>
public sealed class Connection : IDisposable
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly object _lock = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentQueue<(byte[] bytes, bool picture)> _writeQ = new();
    // Audio/Volume/Ping must not sit behind multi‑MB tile/video frames (receiver audio
    // buffer is ~30 ms). Drained before _writeQ. Cap drops newest when full so WS and
    // latency stay bounded — Mac puts these on the cursor channel for the same reason.
    private readonly ConcurrentQueue<(byte[] bytes, bool picture)> _prioQ = new();
    private readonly AutoResetEvent _writePulse = new(false);
    private bool _closed;
    private int _queued;
    private int _queuedPictures;
    private long _bytesSent;
    private long _bytesQueued;
    private int _prioQueued;
    private long _prioBytesQueued;
    private int _prioWrittenSinceNormal; // fair-share: do not let Audio starve Tile/Video on main
    // Hard cap — stalled WriteLoop + large video frames otherwise grow WS without bound.
    // Hybrid sends VideoFrame+TileFrame as a pair (2 msgs). Cap must be ≥4 or the
    // second half of a pair is silently dropped when qm was already 1 (half-drained).
    private const int MaxQueuedMessages = 6;
    private const long MaxQueuedBytes = 2L << 20;
    private const long MaxPriorityQueuedBytes = 192L << 10; // ~1 s of PCM — underruns sounded choppy at 0.5 s
    private const int MaxPrioBeforeNormal = 2;

    /// <summary>Assignable (Mac-style) so a handover can replace handlers.</summary>
    public Action<Message>? OnMessage { get; set; }
    public Action<string>? OnClose { get; set; }

    private Connection(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public bool IsClosed
    {
        get { lock (_lock) return _closed; }
    }

    /// <summary>Mac Connection.queuedFrames — tile/probe pictures not yet written.</summary>
    public int QueuedFrames
    {
        get { lock (_lock) return _queuedPictures; }
    }

    public int QueuedMessages
    {
        get { lock (_lock) return _queued; }
    }

    /// <summary>Non-priority backlog only (tile/video). Priority audio/cursor must not trip the stream busy gate.</summary>
    public int QueuedNormalMessages
    {
        get { lock (_lock) return Math.Max(0, _queued - _prioQueued); }
    }

    /// <summary>App-queue bytes not yet written (Mac Connection.queuedBytes).</summary>
    public long QueuedBytes
    {
        get { lock (_lock) return _bytesQueued; }
    }

    /// <summary>Windows TCP_INFO (SIO_TCP_INFO, version 0): the kernel's view of this socket, the counterpart of the Mac's TCPInfo.</summary>
    public readonly record struct TcpStats(
        double RttMs, double MinRttMs, long BytesInFlight, long BytesOut, long BytesRetrans, long SendWindow, long Cwnd);

    private const int SioTcpInfo = unchecked((int)0xD8000027);

    /// <summary>Null when the socket is closed or the OS does not support it (Windows 10 1703+ does).</summary>
    public TcpStats? GetTcpInfo()
    {
        try
        {
            var input = BitConverter.GetBytes(0);          // TCP_INFO_v0
            var output = new byte[128];
            var n = _client.Client.IOControl((IOControlCode)SioTcpInfo, input, output);
            if (n < 88) return null;
            return new TcpStats(
                RttMs: BitConverter.ToUInt32(output, 20) / 1000.0,
                MinRttMs: BitConverter.ToUInt32(output, 24) / 1000.0,
                BytesInFlight: BitConverter.ToUInt32(output, 28),
                BytesOut: (long)BitConverter.ToUInt64(output, 48),
                BytesRetrans: BitConverter.ToUInt32(output, 68),
                SendWindow: BitConverter.ToUInt32(output, 36),
                Cwnd: BitConverter.ToUInt32(output, 32));
        }
        catch { return null; }
    }

    /// <summary>Mac FrameCounters.bytes — take-and-reset for 1 Hz SenderStats.</summary>
    public long TakeBytesSent()
    {
        lock (_lock)
        {
            var n = _bytesSent;
            _bytesSent = 0;
            return n;
        }
    }

    public static async Task<Connection> ConnectAsync(string host, int port, TimeSpan timeout, CancellationToken ct = default)
    {
        Exception? last = null;
        // Mac Receiver sometimes needs a beat after a hard disconnect before accept() resumes.
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            var client = new TcpClient();
            try
            {
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
                linked.CancelAfter(timeout);
                await client.ConnectAsync(host, port, linked.Token).ConfigureAwait(false);
                client.NoDelay = true;
                // Probe frames are up to ~1 MiB; 1.5s + 64 KiB SNDBUF timed out mid-write
                // and left sessions stuck on "Measuring link" with no ProbeResult.
                client.SendTimeout = 5000;
                client.ReceiveTimeout = 0;
                // Modest SNDBUF so QueuedFrames reflects backlog without killing probe writes.
                client.Client.SendBufferSize = 256 * 1024;
                return new Connection(client);
            }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or IOException)
            {
                last = ex;
                try { client.Dispose(); } catch { /* ignore */ }
                if (attempt == 3 || ct.IsCancellationRequested) break;
                await Task.Delay(1500, ct).ConfigureAwait(false);
            }
        }
        throw last ?? new IOException($"connect {host}:{port} failed");
    }

    public void Start()
    {
        _ = Task.Run(ReadLoop);
        _ = Task.Run(WriteLoop);
    }

    public void Send(Message message)
    {
        // Count VideoFrame too — hybrid pairs otherwise hide backlog behind QueuedFrames==0.
        var picture = message.Type is MessageType.TileFrame or MessageType.Probe or MessageType.VideoFrame;
        // Never drop probe/handshake — dropping Probe End stuck "Measuring link";
        // dropping Ping during probe tripped the receiver idle watchdog (~4s).
        // Only ephemeral messages may be dropped. A dropped VideoFrame breaks the P-frame chain (the
        // receiver then reports "video decoding keeps failing" and ends the session); a dropped TileFrame
        // leaves its tiles stale or lossy for good because the encoder already committed them as sent.
        // Backpressure for pictures is the session's job (it does not produce frames while the queue is busy).
        // Audio/Volume/Cursor ride a priority queue so they are not stuck behind pictures.
        // CursorPos must be priority too: on the cursor channel Audio would otherwise keep
        // _queued high and the droppable check would silently discard every cursor update.
        var priority = message.Type is MessageType.Audio or MessageType.Volume or MessageType.Ping
            or MessageType.CursorPos or MessageType.CursorImage;
        // Cursor stays priority for ordering, but may drop under backlog (unlike Audio).
        var droppable = message.Type is MessageType.SenderStats
            or MessageType.CursorPos or MessageType.CursorImage;
        lock (_lock)
        {
            if (_closed)
                return;
            if (droppable && (_queued >= MaxQueuedMessages || _bytesQueued >= MaxQueuedBytes))
                return; // prefer fresh media over multi-second backlog
        }
        var frame = Framing.Encode(message);
        lock (_lock)
        {
            if (_closed)
                return;
            if (droppable && (_queued >= MaxQueuedMessages || _bytesQueued >= MaxQueuedBytes))
                return;
            // Audio backlog: drop oldest priority frames so the stream stays continuous (dropping
            // newest punched holes — receiver underruns restarted and cut the tails of notes).
            if (priority)
            {
                while (_prioBytesQueued + frame.Length > MaxPriorityQueuedBytes && _prioQ.TryDequeue(out var old))
                {
                    _prioBytesQueued = Math.Max(0, _prioBytesQueued - old.bytes.Length);
                    _bytesQueued = Math.Max(0, _bytesQueued - old.bytes.Length);
                    _prioQueued = Math.Max(0, _prioQueued - 1);
                    _queued = Math.Max(0, _queued - 1);
                }
            }
            _queued++;
            _bytesQueued += frame.Length;
            if (priority)
            {
                _prioQueued++;
                _prioBytesQueued += frame.Length;
            }
            if (picture)
                _queuedPictures++;
        }
        if (priority) _prioQ.Enqueue((frame, picture));
        else _writeQ.Enqueue((frame, picture));
        _writePulse.Set();
    }

    public Message ReadOne()
    {
        var reader = new FrameReader(_stream);
        return reader.Next() ?? throw new IOException("connection closed");
    }

    private bool TryDequeueWrite(out (byte[] bytes, bool picture, bool priority) item)
    {
        // Fair share: continuous Audio on the main link used to drain prio forever and starve
        // Tile/Video (frozen picture, "still connecting" feel). Yield to a normal message regularly.
        if (!_writeQ.IsEmpty && _prioWrittenSinceNormal >= MaxPrioBeforeNormal
            && _writeQ.TryDequeue(out var yielded))
        {
            _prioWrittenSinceNormal = 0;
            item = (yielded.bytes, yielded.picture, false);
            return true;
        }
        if (_prioQ.TryDequeue(out var prio))
        {
            _prioWrittenSinceNormal++;
            item = (prio.bytes, prio.picture, true);
            return true;
        }
        if (_writeQ.TryDequeue(out var normal))
        {
            _prioWrittenSinceNormal = 0;
            item = (normal.bytes, normal.picture, false);
            return true;
        }
        item = default;
        return false;
    }

    private void WriteLoop()
    {
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                while (TryDequeueWrite(out var item))
                {
                    // One complete framed message per write — never splice another message into a
                    // mid-payload (that corrupts FrameReader and flaps the session).
                    _stream.Write(item.bytes, 0, item.bytes.Length);
                    lock (_lock)
                    {
                        _bytesSent += item.bytes.Length;
                        _bytesQueued = Math.Max(0, _bytesQueued - item.bytes.Length);
                        _queued = Math.Max(0, _queued - 1);
                        if (item.priority)
                        {
                            _prioQueued = Math.Max(0, _prioQueued - 1);
                            _prioBytesQueued = Math.Max(0, _prioBytesQueued - item.bytes.Length);
                        }
                        if (item.picture)
                            _queuedPictures = Math.Max(0, _queuedPictures - 1);
                    }
                }
                _writePulse.WaitOne(50);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or SocketException or OperationCanceledException)
        {
            NotifyClose("send: " + ex.Message);
        }
        catch (Exception ex)
        {
            NotifyClose("send: " + ex.Message);
        }
    }

    private void ReadLoop()
    {
        try
        {
            var reader = new FrameReader(_stream);
            while (!_cts.IsCancellationRequested)
            {
                var msg = reader.Next();
                if (msg is null)
                {
                    NotifyClose("eof");
                    return;
                }
                OnMessage?.Invoke(msg.Value);
            }
        }
        catch (Exception ex)
        {
            NotifyClose(ex.Message);
        }
    }

    private void NotifyClose(string reason)
    {
        lock (_lock)
        {
            if (_closed)
                return;
            _closed = true;
        }
        try { _cts.Cancel(); } catch { /* ignore */ }
        try { _writePulse.Set(); } catch { /* ignore */ }
        OnClose?.Invoke(reason);
    }

    /// <summary>Mac <c>closeAfterFlush</c>: finish queued writes, then dispose (handover old link).</summary>
    public void CloseAfterFlush(string reason = "closed")
    {
        try
        {
            for (var i = 0; i < 50; i++)
            {
                lock (_lock)
                {
                    if (_closed || _queued == 0) break;
                }
                Thread.Sleep(20);
            }
        }
        catch { /* ignore */ }
        NotifyClose(reason);
        DisposeSocketOnly();
    }

    public void Dispose()
    {
        NotifyClose("disposed");
        DisposeSocketOnly();
    }

    private void DisposeSocketOnly()
    {
        try { _stream.Dispose(); } catch { /* ignore */ }
        try { _client.Dispose(); } catch { /* ignore */ }
        try { _writePulse.Dispose(); } catch { /* ignore */ }
        try { _cts.Dispose(); } catch { /* ignore */ }
    }
}
