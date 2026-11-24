using Afterscreen.Protocol;
using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class FasterLinkPolicyTests
{
    private static FasterLinkPolicy.Tries Tries(LinkKind kind = LinkKind.usb, double at = 100, int count = 1, int reconnects = 0) =>
        new() { Receiver = "iMac", Kind = kind, At = at, Count = count, Reconnects = reconnects };

    private static FasterLinkPolicy.Decision Next(FasterLinkPolicy.Tries? last, double now, bool seamless = true) =>
        FasterLinkPolicy.Try(last, "iMac", LinkKind.usb, now, seamless);

    [Fact]
    public void FasterLinkHandoversBackOffAndStartOver()
    {
        Assert.IsType<FasterLinkPolicy.Decision.Go>(Next(null, 100));
        Assert.Equal(6, Assert.IsType<FasterLinkPolicy.Decision.Wait>(Next(Tries(at: 100, count: 1), 104)).Seconds);
        var go2 = Assert.IsType<FasterLinkPolicy.Decision.Go>(Next(Tries(at: 100, count: 1), 110));
        Assert.Equal(2, go2.Next.Count);
        Assert.Equal(10, Assert.IsType<FasterLinkPolicy.Decision.Wait>(Next(Tries(at: 110, count: 2), 120)).Seconds);
        var go3 = Assert.IsType<FasterLinkPolicy.Decision.Go>(Next(Tries(at: 100, count: 2), 400));
        Assert.Equal(3, go3.Next.Count);
        Assert.IsType<FasterLinkPolicy.Decision.Never>(Next(Tries(at: 100, count: 5, reconnects: 2), 500));
    }

    [Fact]
    public void FasterLinkOutcomeMessages()
    {
        Assert.Equal("Switched to the faster Ethernet", FasterLinkPolicy.FasterOutcome(LinkKind.ethernet, LinkKind.ethernet));
        Assert.Equal("Ethernet did not connect; on Wi-Fi instead", FasterLinkPolicy.FasterOutcome(LinkKind.ethernet, LinkKind.wifi));
    }

    [Fact]
    public void ConnectsWithoutCodeMatchesMacCableRules()
    {
        Assert.True(FasterLinkPolicy.ConnectsWithoutCode(paired: true, route: LinkKind.wifi));
        Assert.True(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: LinkKind.thunderbolt));
        Assert.True(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: LinkKind.usb));
        Assert.True(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: LinkKind.loopback));
        Assert.False(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: LinkKind.ethernet));
        Assert.False(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: LinkKind.wifi));
        Assert.False(FasterLinkPolicy.ConnectsWithoutCode(paired: false, route: null));
    }

    [Fact]
    public void LinkMenuKeepsUnreachablePinnedListed()
    {
        var pinnedGone = LinkMenu.Choices(new[] { LinkKind.thunderbolt, LinkKind.wifi }, LinkKind.usb);
        Assert.Equal(new[] { LinkKind.thunderbolt, LinkKind.wifi, LinkKind.usb }, pinnedGone.Select(c => c.Kind));
        Assert.Equal(new[] { true, true, false }, pinnedGone.Select(c => c.Reachable));
        Assert.Equal(new[] { LinkKind.thunderbolt, LinkKind.wifi },
            LinkMenu.Choices(new[] { LinkKind.thunderbolt, LinkKind.wifi }, LinkKind.wifi).Select(c => c.Kind));
        Assert.Empty(LinkMenu.Choices(Array.Empty<LinkKind>(), null));
    }

    [Fact]
    public void PickAddressUsesPlanThenHeuristic()
    {
        var local = new[]
        {
            new LocalInterface("eth0", "169.254.1.2", "255.255.0.0", LinkKind.ethernet),
            new LocalInterface("wlan0", "192.168.1.10", "255.255.255.0", LinkKind.wifi),
        };
        var addrs = new[] { "192.168.1.20", "169.254.1.50" };
        Assert.Equal("169.254.1.50", RoutePlanner.PickAddress(local, addrs, "auto"));
        Assert.Equal("169.254.1.50", RoutePlanner.PickAddress(local, addrs, "ethernet"));
        Assert.Equal("192.168.1.20", RoutePlanner.PickAddress(local, addrs, "wifi"));

        var noMatch = Array.Empty<LocalInterface>();
        Assert.Equal("169.254.1.50", RoutePlanner.PickAddress(noMatch, addrs, "auto"));
        Assert.Equal("192.168.1.20", RoutePlanner.PickAddress(noMatch, addrs, "wifi"));
    }

    [Fact]
    public void PickDetailedReportsFallbackWhenPreferredMissing()
    {
        var local = new[] { new LocalInterface("wlan0", "192.168.1.10", "255.255.255.0", LinkKind.wifi) };
        var addrs = new[] { "192.168.1.20" };
        var pick = RoutePlanner.PickDetailed(local, addrs, "ethernet");
        Assert.True(pick.FellBack);
        Assert.Equal(LinkKind.wifi, pick.Got);
        Assert.Equal("192.168.1.20", pick.Address);
    }
}
