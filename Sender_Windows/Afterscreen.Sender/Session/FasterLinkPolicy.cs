using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>Mac <c>AppModel.fasterLinkTry</c> / <c>fasterLinkOutcome</c>: backoff for mid-session upgrades.</summary>
public static class FasterLinkPolicy
{
    public sealed class Tries
    {
        public string Receiver { get; init; } = "";
        public LinkKind Kind { get; init; }
        public double At { get; set; }
        public int Count { get; set; }
        public int Reconnects { get; set; }
    }

    public abstract record Decision
    {
        public sealed record Go(Tries Next) : Decision;
        public sealed record Wait(double Seconds) : Decision;
        public sealed record Never : Decision;
    }

    /// <summary>
    /// Seamless (handover) waits double from 10 s, ten minutes at most.
    /// Twenty quiet minutes restart the waits. Two reconnects stop until unplug/wake.
    /// </summary>
    public static Decision Try(Tries? last, string receiver, LinkKind kind, double now, bool seamless)
    {
        if (last is null || last.Receiver != receiver || last.Kind != kind)
        {
            return new Decision.Go(new Tries
            {
                Receiver = receiver,
                Kind = kind,
                At = now,
                Count = 1,
                Reconnects = seamless ? 0 : 1,
            });
        }
        var next = new Tries
        {
            Receiver = last.Receiver,
            Kind = last.Kind,
            At = last.At,
            Count = last.Count,
            Reconnects = last.Reconnects,
        };
        if (now >= next.At + 1200) next.Count = 0;
        if (next.Reconnects >= 2) return new Decision.Never();
        var gap = next.Count == 0 ? 0
            : seamless ? Math.Min(600, 10 * Math.Pow(2, next.Count - 1))
            : 10;
        if (now < next.At + gap) return new Decision.Wait(next.At + gap - now);
        next.At = now;
        next.Count += 1;
        if (!seamless) next.Reconnects += 1;
        return new Decision.Go(next);
    }

    public static string LinkName(LinkKind? kind) => kind switch
    {
        LinkKind.thunderbolt => "Thunderbolt",
        LinkKind.usb => "USB",
        LinkKind.ethernet => "Ethernet",
        LinkKind.wifi => "Wi-Fi",
        LinkKind.loopback => "Loopback",
        _ => "the link",
    };

    /// <summary>Mac <c>AppModel.connectsWithoutCode</c>: cable TB/USB/loopback skip the on-screen code.</summary>
    public static bool ConnectsWithoutCode(bool paired, LinkKind? route) =>
        paired || route is LinkKind.thunderbolt or LinkKind.usb or LinkKind.loopback;

    public static string FasterOutcome(LinkKind wanted, LinkKind? got) =>
        got == wanted
            ? $"Switched to the faster {LinkName(wanted)}"
            : $"{LinkName(wanted)} did not connect; on {LinkName(got)} instead";
}
