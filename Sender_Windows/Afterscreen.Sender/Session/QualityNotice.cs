namespace Afterscreen.Sender.Session;

/// <summary>
/// Mac <c>QualityNotice</c>: when to tell the user the picture was turned down. Severe and lasting only: short dips pass
/// unannounced. Fed once a second with the video bitrate now and at the start.
/// </summary>
public sealed class QualityNotice
{
    /// <summary>At or under this share of the start: severe.</summary>
    public const double SevereShare = 0.5;
    public const int SevereSeconds = 5;
    /// <summary>Back over this share this long: the episode ends.</summary>
    public const double RecoveredShare = 0.9;
    public const int RecoveredSeconds = 30;
    /// <summary>Least time between two notices.</summary>
    public const double QuietSeconds = 600;

    /// <summary>Severe long enough; ends once recovered.</summary>
    public bool Lowered { get; private set; }
    private int _severe;
    private int _recovered;

    /// <summary>True when the receiver should show the notice. <paramref name="lastShown"/> spans sessions: reconnects stay quiet too.</summary>
    public bool Update(int bitrate, int start, double now, ref double? lastShown)
    {
        if (start <= 0) return false;
        var share = (double)bitrate / start;
        _severe = share <= SevereShare ? _severe + 1 : 0;
        _recovered = share >= RecoveredShare ? _recovered + 1 : 0;
        if (Lowered)
        {
            if (_recovered >= RecoveredSeconds) Lowered = false;
            return false;
        }
        if (_severe < SevereSeconds) return false;
        Lowered = true;
        if (lastShown is { } last && now - last < QuietSeconds) return false;
        lastShown = now;
        return true;
    }
}
