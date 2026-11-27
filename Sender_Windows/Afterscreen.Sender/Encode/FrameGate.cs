namespace Afterscreen.Sender.Encode;

/// <summary>
/// Mac <c>FrameGate</c>: paces to <see cref="IntervalMs"/>; holds only the newest unsent frame.
/// Thread-safe: capture offers from its own thread while the stream loop takes.
/// </summary>
public sealed class FrameGate<T> where T : class
{
    private readonly object _sync = new();
    private T? _pending;
    private long _lastEmit = long.MinValue / 2;

    public double IntervalMs { get; }

    public FrameGate(double intervalMs) => IntervalMs = Math.Max(1, intervalMs);

    public T? Pending { get { lock (_sync) return _pending; } }

    /// <summary>True when an unsent frame was replaced (dropped).</summary>
    public bool Offer(T frame)
    {
        lock (_sync)
        {
            var replaced = _pending is not null;
            _pending = frame;
            return replaced;
        }
    }

    /// <summary>
    /// Offer that folds the replaced frame into the newer one (<paramref name="merge"/>(dropped, newer)) atomically.
    /// <paramref name="droppedOpen"/>: a frame was replaced while the gate was open (Mac: a frame lost, not pacing).
    /// </summary>
    public bool Offer(T frame, long nowMs, Action<T, T> merge, out bool droppedOpen)
    {
        lock (_sync)
        {
            var dropped = _pending;
            if (dropped is not null) merge(dropped, frame);
            _pending = frame;
            droppedOpen = dropped is not null && DelayLocked(nowMs) == 0;
            return dropped is not null;
        }
    }

    public double DelayMs(long nowMs) { lock (_sync) return DelayLocked(nowMs); }

    private double DelayLocked(long nowMs) => Math.Max(0, _lastEmit + IntervalMs - nowMs);

    public T? Take(long nowMs, bool busy)
    {
        lock (_sync)
        {
            if (_pending is null || busy || nowMs - _lastEmit < IntervalMs)
                return default;
            var frame = _pending;
            _pending = default;
            _lastEmit = nowMs;
            return frame;
        }
    }

    public void Clear() { lock (_sync) _pending = default; }
}
