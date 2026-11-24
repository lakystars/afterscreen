using Afterscreen.Protocol;
using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class RoutePlannerTests
{
    [Fact]
    public void ClassifyUsesNameHeuristicsForThunderboltAndUsb()
    {
        Assert.Equal(LinkKind.thunderbolt, RoutePlanner.Classify("Thunderbolt Ethernet Bridge",
            System.Net.NetworkInformation.NetworkInterfaceType.Ethernet, false));
        Assert.Equal(LinkKind.usb, RoutePlanner.Classify("Remote NDIS based Internet Sharing Device",
            System.Net.NetworkInformation.NetworkInterfaceType.Ethernet, false));
        Assert.Equal(LinkKind.ethernet, RoutePlanner.Classify("Ethernet",
            System.Net.NetworkInformation.NetworkInterfaceType.Ethernet, false));
        Assert.Equal(LinkKind.wifi, RoutePlanner.Classify("Wi-Fi",
            System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211, false));
    }

    [Fact]
    public void ClassifyUsesDescriptionAndPnpBusType()
    {
        var eth = System.Net.NetworkInformation.NetworkInterfaceType.Ethernet;
        Assert.Equal(LinkKind.thunderbolt, RoutePlanner.Classify("Ethernet 4", "Intel(R) Thunderbolt(TM) Networking", eth, false));
        Assert.Equal(LinkKind.thunderbolt, RoutePlanner.Classify("Ethernet 5", "USB4 Networking", eth, false,
            pnpDeviceId: @"USB\VID_8087&PID_0B23\1"));
        Assert.Equal(LinkKind.usb, RoutePlanner.Classify("Ethernet 6", "Realtek USB GbE Family Controller", eth, false,
            pnpDeviceId: @"USB\VID_0BDA&PID_8153\00"));
        Assert.Equal(LinkKind.usb, RoutePlanner.Classify("Ethernet 7", "Some Dongle", eth, false,
            pnpDeviceId: @"USB\VID_1234&PID_5678\1"));
        Assert.Equal(LinkKind.ethernet, RoutePlanner.Classify("Ethernet", "Intel(R) Ethernet Connection", eth, false,
            pnpDeviceId: @"PCI\VEN_8086&DEV_15F3\3&1"));
    }

    [Fact]
    public void PickDetailedPrefersThunderboltAndUsbPins()
    {
        // Distinct /24s so Plan does not treat every 169.254.* as one cable subnet.
        var local = new[]
        {
            new LocalInterface("tb0", "169.254.10.2", "255.255.255.0", LinkKind.thunderbolt),
            new LocalInterface("usb0", "169.254.20.2", "255.255.255.0", LinkKind.usb),
            new LocalInterface("wlan0", "192.168.1.10", "255.255.255.0", LinkKind.wifi),
        };
        var remote = new[] { "169.254.10.50", "169.254.20.50", "192.168.1.20" };
        var tb = RoutePlanner.PickDetailed(local, remote, "thunderbolt");
        Assert.False(tb.FellBack);
        Assert.Equal(LinkKind.thunderbolt, tb.Got);
        Assert.Equal("169.254.10.50", tb.Address);
        var usb = RoutePlanner.PickDetailed(local, remote, "usb");
        Assert.False(usb.FellBack);
        Assert.Equal(LinkKind.usb, usb.Got);
        Assert.Equal("169.254.20.50", usb.Address);
        var missing = RoutePlanner.PickDetailed(
            new[] { new LocalInterface("wlan0", "192.168.1.10", "255.255.255.0", LinkKind.wifi) },
            new[] { "192.168.1.20" }, "thunderbolt");
        Assert.True(missing.FellBack);
        Assert.Equal(LinkKind.wifi, missing.Got);
    }

    [Fact]
    public void AutomaticLinkMovesOnlyToAFasterOne()
    {
        Assert.Equal(LinkKind.ethernet, RoutePlanner.Upgrade(LinkKind.wifi, new[] { LinkKind.ethernet, LinkKind.wifi }));
        Assert.Equal(LinkKind.thunderbolt, RoutePlanner.Upgrade(LinkKind.ethernet, new[] { LinkKind.thunderbolt, LinkKind.ethernet, LinkKind.wifi }));
        Assert.Null(RoutePlanner.Upgrade(LinkKind.ethernet, new[] { LinkKind.ethernet, LinkKind.wifi }));
        Assert.Null(RoutePlanner.Upgrade(LinkKind.thunderbolt, new[] { LinkKind.usb, LinkKind.wifi }));
        Assert.Null(RoutePlanner.Upgrade(LinkKind.loopback, new[] { LinkKind.wifi }));
        Assert.Null(RoutePlanner.Upgrade(null, new[] { LinkKind.ethernet }));
        Assert.True(RoutePlanner.BelowFastest(LinkKind.wifi));
        Assert.True(RoutePlanner.BelowFastest(LinkKind.usb));
        Assert.False(RoutePlanner.BelowFastest(LinkKind.thunderbolt));
        Assert.False(RoutePlanner.BelowFastest(LinkKind.loopback));
        Assert.False(RoutePlanner.BelowFastest(null));
    }

    [Fact]
    public void PlanMatchesSameSubnetAndPrefersFasterKinds()
    {
        var local = new[]
        {
            new LocalInterface("eth0", "169.254.1.2", "255.255.0.0", LinkKind.ethernet),
            new LocalInterface("wlan0", "192.168.1.10", "255.255.255.0", LinkKind.wifi),
        };
        var remote = new[]
        {
            new RemoteAddress("169.254.1.50"),
            new RemoteAddress("192.168.1.20"),
        };
        var routes = RoutePlanner.Plan(local, remote);
        Assert.Equal(2, routes.Count);
        Assert.Equal(LinkKind.ethernet, routes[0].Kind);
        Assert.Equal("169.254.1.50", routes[0].Address);
        Assert.Equal(LinkKind.wifi, routes[1].Kind);
        Assert.Equal(new[] { LinkKind.ethernet, LinkKind.wifi }, RoutePlanner.Kinds(routes));
    }

    [Fact]
    public void SelectAndFallbackRespectPreferredLink()
    {
        var routes = new[]
        {
            new Route("eth0", "169.254.1.50", LinkKind.ethernet),
            new Route("wlan0", "192.168.1.20", LinkKind.wifi),
        };
        var (chosen, fell) = RoutePlanner.Select(routes, LinkKind.wifi);
        Assert.False(fell);
        Assert.Single(chosen);
        Assert.Equal(LinkKind.wifi, chosen[0].Kind);
        Assert.Single(RoutePlanner.Fallback(routes, LinkKind.wifi));
        Assert.Equal(LinkKind.ethernet, RoutePlanner.Fallback(routes, LinkKind.wifi)[0].Kind);

        var (all, fellBack) = RoutePlanner.Select(routes, LinkKind.thunderbolt);
        Assert.True(fellBack);
        Assert.Equal(2, all.Count);
        Assert.Empty(RoutePlanner.Fallback(routes, LinkKind.thunderbolt));
    }

    [Fact]
    public void OwnAddressBecomesLoopback()
    {
        var local = new[] { new LocalInterface("eth0", "192.168.1.10", "255.255.255.0", LinkKind.ethernet) };
        var remote = new[] { new RemoteAddress("192.168.1.10") };
        var routes = RoutePlanner.Plan(local, remote);
        Assert.Single(routes);
        Assert.Equal(LinkKind.loopback, routes[0].Kind);
        Assert.Equal("127.0.0.1", routes[0].Address);
    }
}
