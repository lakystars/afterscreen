namespace Afterscreen.Sender.Encode;

/// <summary>
/// Mac <c>RateControl</c>: video bitrate backs off while the link queues, recovers slowly.
/// Windows: used for SW start floor today; full TCP sampling lands with FrameStreamer port.
/// </summary>
public sealed class RateControl
{
    public const double QueueingMs = 30;
    public const int BaseWindow = 30;
    public const double DrainLimit = 0.15;
    public const int StalledWindow = 64 << 10;
    public const double DrainingShare = 0.97;
    public const double Backoff = 0.7;
    public const double Recovery = 1.1;
    public const int ClearSeconds = 3;

    public int Start { get; }
    public int Floor { get; }
    public int Bitrate { get; private set; }
    private readonly double _fps;
    private readonly List<double> _rtts = new();
    private bool _rttWasHigh;
    private int? _draining;
    private int _clear;

    public RateControl(int start, double fps)
    {
        Start = start;
        Floor = Math.Max(5_000_000, start / 8);
        Bitrate = start;
        _fps = Math.Max(1, fps);
    }

    /// <summary>Mac RateControl.newLink</summary>
    public void NewLink()
    {
        _rtts.Clear();
        _rttWasHigh = false;
        _draining = null;
        _clear = 0;
    }

    public readonly struct Sample
    {
        public int Frames { get; init; }
        public double SentBps { get; init; }
        public double? RttMs { get; init; }
        public int Buffered { get; init; }
        public bool ReceiverLimited { get; init; }
        public bool FullFrame { get; init; }
    }

    /// <summary>Mac RateControl.update — new bitrate, or null when unchanged.</summary>
    public int? Update(Sample s)
    {
        if (s.Frames < _fps / 4)
        {
            _rttWasHigh = false;
            _draining = null;
            return null;
        }

        var rttHigh = false;
        if (s.RttMs is > 0 and var rtt && s.SentBps >= Bitrate / 4.0)
        {
            _rtts.Add(rtt);
            if (_rtts.Count > BaseWindow)
                _rtts.RemoveAt(0);
            rttHigh = rtt - (_rtts.Min()) > QueueingMs;
        }

        var over = !s.ReceiverLimited && !s.FullFrame && s.SentBps > 0
                   && s.Buffered * 8.0 / s.SentBps > DrainLimit;
        var backlog = over && s.Buffered >= (_draining ?? 0) * DrainingShare;
        _draining = over ? s.Buffered : null;
        var queued = backlog || (rttHigh && _rttWasHigh);
        _rttWasHigh = rttHigh;

        int next;
        if (queued)
        {
            _clear = 0;
            next = Math.Max(Floor, (int)(Bitrate * Backoff));
        }
        else if (over)
        {
            _clear = 0;
            return null;
        }
        else if (rttHigh)
        {
            return null;
        }
        else
        {
            _clear++;
            if (_clear < ClearSeconds)
                return null;
            next = Math.Min(Start, (int)(Bitrate * Recovery));
        }

        if (next == Bitrate)
            return null;
        Bitrate = next;
        return next;
    }
}
