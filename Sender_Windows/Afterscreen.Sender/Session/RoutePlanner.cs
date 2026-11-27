using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>Local NIC used when planning routes to a receiver.</summary>
public readonly record struct LocalInterface(string Name, string Ip, string Netmask, LinkKind Kind, IReadOnlyList<string>? V6 = null);

/// <summary>Receiver address; <see cref="Via"/> is the answering local interface if mDNS reported it.</summary>
public readonly record struct RemoteAddress(string Ip, string? Via = null);

/// <summary>One (interface, receiver address, kind) path.</summary>
public readonly record struct Route(string Interface, string Address, LinkKind Kind);

/// <summary>
/// Mac <c>RoutePlanner</c>: orders (interface, receiver address) pairs.
/// Thunderbolt/USB use name+description heuristics and Win32 <c>PNPDeviceID</c> (BusType stand-in).
/// </summary>
public static class RoutePlanner
{
    private static readonly LinkKind[] Priority =
    {
        LinkKind.thunderbolt, LinkKind.usb, LinkKind.ethernet, LinkKind.wifi,
    };

    private static readonly object BusHintsLock = new();
    private static Dictionary<string, string>? _busHintsByName;
    private static long _busHintsUntilTick;

    /// <summary>
    /// Address that answered on a known interface routes only there.
    /// Link-local subnets repeat on every cable. IPv4 first; IPv6 where mDNS answered on that interface.
    /// </summary>
    public static IReadOnlyList<Route> Plan(IReadOnlyList<LocalInterface> local, IReadOnlyList<RemoteAddress> remote)
    {
        var remoteV4 = remote.Where(r => ParseIpv4(r.Ip) is not null).ToList();
        var remoteV6 = remote.Where(r => ParseIpv4(r.Ip) is null).ToList();
        foreach (var r in remote)
        {
            if (local.Any(l =>
                    (!string.IsNullOrEmpty(l.Ip) && l.Ip == r.Ip)
                    || (l.V6?.Contains(Unscoped(r.Ip)) ?? false)))
                return new[] { new Route(LoopbackName, "127.0.0.1", LinkKind.loopback) };
        }

        var routes = new List<Route>();
        foreach (var kind in Priority)
        {
            foreach (var iface in local.Where(i => i.Kind == kind))
            {
                if (ParseIpv4(iface.Ip) is { } ip && ParseIpv4(iface.Netmask) is { } mask
                    && remoteV4.FirstOrDefault(r =>
                        r.Via is { } via ? via == iface.Name
                            : ParseIpv4(r.Ip) is { } rip && (rip & mask) == (ip & mask)) is { Ip.Length: > 0 } matchV4)
                {
                    routes.Add(new Route(iface.Name, matchV4.Ip, kind));
                }
                else if (remoteV6.FirstOrDefault(r => r.Via == iface.Name) is { Ip.Length: > 0 } matchV6)
                {
                    routes.Add(new Route(iface.Name, matchV6.Ip, kind));
                }
            }
        }
        return routes;
    }

    public static string Unscoped(string ip)
    {
        var i = ip.IndexOf('%');
        return i < 0 ? ip : ip[..i];
    }

    /// <summary>Links in route order, each once.</summary>
    public static IReadOnlyList<LinkKind> Kinds(IReadOnlyList<Route> routes)
    {
        var list = new List<LinkKind>();
        foreach (var r in routes)
            if (!list.Contains(r.Kind)) list.Add(r.Kind);
        return list;
    }

    /// <summary>Automatic link mid-session: the faster link to move to. Null if already fastest.</summary>
    public static LinkKind? Upgrade(LinkKind? current, IReadOnlyList<LinkKind> available)
    {
        if (current is null) return null;
        var now = Array.IndexOf(Priority, current.Value);
        if (now < 0 || available.Count == 0) return null;
        var fastest = available[0];
        var rank = Array.IndexOf(Priority, fastest);
        if (rank < 0 || rank >= now) return null;
        return fastest;
    }

    /// <summary>A faster kind of link could take over.</summary>
    public static bool BelowFastest(LinkKind? current)
    {
        if (current is null) return false;
        var i = Array.IndexOf(Priority, current.Value);
        return i > 0;
    }

    /// <summary>Routes over the chosen link; falls back to all when that link is gone.</summary>
    public static (IReadOnlyList<Route> Routes, bool FellBack) Select(IReadOnlyList<Route> routes, LinkKind? prefer)
    {
        if (prefer is null) return (routes, false);
        var chosen = routes.Where(r => r.Kind == prefer).ToList();
        return chosen.Count == 0 ? (routes, true) : (chosen, false);
    }

    /// <summary>Other links' routes, tried when the chosen link's fail.</summary>
    public static IReadOnlyList<Route> Fallback(IReadOnlyList<Route> routes, LinkKind? prefer)
    {
        if (prefer is null || !routes.Any(r => r.Kind == prefer)) return Array.Empty<Route>();
        return routes.Where(r => r.Kind != prefer).ToList();
    }

    /// <summary>Classify a Windows NIC (name only — tests / callers without description).</summary>
    public static LinkKind Classify(string name, NetworkInterfaceType type, bool isLoopback) =>
        Classify(name, description: null, type, isLoopback, pnpDeviceId: null);

    /// <summary>
    /// Classify a Windows NIC. Thunderbolt/USB4 keywords win over a USB bus id (Mac: Thunderbolt before NCM).
    /// <paramref name="pnpDeviceId"/> is Win32 <c>PNPDeviceID</c> (USB\… ≈ USB BusType).
    /// </summary>
    public static LinkKind Classify(
        string name, string? description, NetworkInterfaceType type, bool isLoopback, string? pnpDeviceId = null)
    {
        if (isLoopback || name.Equals("lo", StringComparison.OrdinalIgnoreCase))
            return LinkKind.loopback;
        var text = $"{name} {description}";
        if (LooksThunderbolt(text) || LooksThunderbolt(pnpDeviceId))
            return LinkKind.thunderbolt;
        if (IsUsbBus(pnpDeviceId) || LooksUsb(text))
            return LinkKind.usb;
        return type switch
        {
            NetworkInterfaceType.Wireless80211 => LinkKind.wifi,
            NetworkInterfaceType.Ethernet
                or NetworkInterfaceType.Ethernet3Megabit
                or NetworkInterfaceType.GigabitEthernet
                or NetworkInterfaceType.FastEthernetT
                or NetworkInterfaceType.FastEthernetFx => LinkKind.ethernet,
            _ => LinkKind.unsupported,
        };
    }

    internal static bool LooksThunderbolt(string? s) =>
        !string.IsNullOrEmpty(s)
        && (s.Contains("thunderbolt", StringComparison.OrdinalIgnoreCase)
            || s.Contains("tb3", StringComparison.OrdinalIgnoreCase)
            || s.Contains("tb4", StringComparison.OrdinalIgnoreCase)
            || s.Contains("usb4", StringComparison.OrdinalIgnoreCase));

    internal static bool LooksUsb(string? s) =>
        !string.IsNullOrEmpty(s)
        && (s.Contains("usb", StringComparison.OrdinalIgnoreCase)
            || s.Contains("rndis", StringComparison.OrdinalIgnoreCase)
            || s.Contains("remote ndis", StringComparison.OrdinalIgnoreCase)
            || s.Contains("ncm", StringComparison.OrdinalIgnoreCase)
            || s.Contains("tethering", StringComparison.OrdinalIgnoreCase));

    internal static bool IsUsbBus(string? pnpDeviceId) =>
        !string.IsNullOrEmpty(pnpDeviceId)
        && pnpDeviceId.StartsWith("USB\\", StringComparison.OrdinalIgnoreCase);

    /// <summary>Up NICs with IPv4 (and optional IPv6), excluding tunnel/unsupported kinds.</summary>
    public static IReadOnlyList<LocalInterface> CurrentInterfaces()
    {
        var hints = BusHintsByName();
        var list = new List<LocalInterface>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            hints.TryGetValue(nic.Name, out var pnp);
            var kind = Classify(nic.Name, nic.Description, nic.NetworkInterfaceType,
                nic.NetworkInterfaceType == NetworkInterfaceType.Loopback, pnp);
            if (kind is LinkKind.unsupported) continue;
            var props = nic.GetIPProperties();
            string ip = "", mask = "";
            var v6 = new List<string>();
            foreach (var uni in props.UnicastAddresses)
            {
                if (uni.Address.AddressFamily == AddressFamily.InterNetwork)
                {
                    ip = uni.Address.ToString();
                    mask = uni.IPv4Mask?.ToString() ?? "255.255.255.0";
                }
                else if (uni.Address.AddressFamily == AddressFamily.InterNetworkV6)
                    v6.Add(Unscoped(uni.Address.ToString()));
            }
            if (string.IsNullOrEmpty(ip) && v6.Count == 0) continue;
            list.Add(new LocalInterface(nic.Name, ip, mask, kind, v6));
        }
        return list;
    }

    /// <summary>NetConnectionID → PNPDeviceID, cached ~30 s (Mac LinkClassifier kinds cache).</summary>
    private static Dictionary<string, string> BusHintsByName()
    {
        lock (BusHintsLock)
        {
            var now = Environment.TickCount64;
            if (_busHintsByName is not null && now < _busHintsUntilTick)
                return _busHintsByName;
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT NetConnectionID, PNPDeviceID FROM Win32_NetworkAdapter WHERE NetConnectionID IS NOT NULL");
                foreach (ManagementObject o in searcher.Get())
                {
                    var id = o["NetConnectionID"] as string;
                    var pnp = o["PNPDeviceID"] as string;
                    if (!string.IsNullOrEmpty(id) && !string.IsNullOrEmpty(pnp))
                        map[id] = pnp;
                }
            }
            catch
            {
                /* WMI unavailable — name/description heuristics still apply */
            }
            _busHintsByName = map;
            _busHintsUntilTick = now + 30_000;
            return map;
        }
    }

    /// <summary>
    /// Preferred link pin for connect: plan local×remote, select thunderbolt/usb/ethernet/wifi/auto.
    /// Falls back to cable-first / pin heuristics when planning finds nothing.
    /// </summary>
    public static string PickAddress(IReadOnlyList<string> remoteAddresses, string preferred) =>
        PickDetailed(CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList(), remoteAddresses, preferred).Address;

    /// <summary>Testable overload with an explicit local NIC list.</summary>
    public static string PickAddress(
        IReadOnlyList<LocalInterface> local, IReadOnlyList<string> remoteAddresses, string preferred) =>
        PickDetailed(local, remoteAddresses, preferred).Address;

    public readonly record struct PickResult(string Address, bool FellBack, LinkKind? Got);

    /// <summary>Parse PreferredLink setting to a kind; null means Automatic.</summary>
    public static LinkKind? ParsePreferred(string? preferred) => preferred switch
    {
        "thunderbolt" => LinkKind.thunderbolt,
        "usb" => LinkKind.usb,
        "ethernet" => LinkKind.ethernet,
        "wifi" => LinkKind.wifi,
        _ => null,
    };

    /// <summary>PreferredLink string for a kind (pin after handover/resume).</summary>
    public static string PreferKey(LinkKind kind) => kind switch
    {
        LinkKind.thunderbolt => "thunderbolt",
        LinkKind.usb => "usb",
        LinkKind.ethernet => "ethernet",
        LinkKind.wifi => "wifi",
        _ => "auto",
    };

    /// <summary>Like <see cref="PickAddress"/> but reports whether Select fell back to another kind.</summary>
    public static PickResult PickDetailed(
        IReadOnlyList<LocalInterface> local, IReadOnlyList<string> remoteAddresses, string preferred)
    {
        if (remoteAddresses.Count == 0) return new("", false, null);
        var prefer = ParsePreferred(preferred);
        var remote = remoteAddresses.Select(a => new RemoteAddress(a)).ToList();
        var routes = Plan(local, remote);
        if (routes.Count == 0)
        {
            // No subnet match: cable-ish prefer → link-local; Wi-Fi → non-link-local.
            var wantCable = prefer is LinkKind.ethernet or LinkKind.thunderbolt or LinkKind.usb or null;
            string addr;
            if (prefer == LinkKind.wifi)
                addr = remoteAddresses.FirstOrDefault(a => !a.StartsWith("169.254.", StringComparison.Ordinal))
                    ?? remoteAddresses[0];
            else if (wantCable && prefer is not null)
                addr = remoteAddresses.FirstOrDefault(a => a.StartsWith("169.254.", StringComparison.Ordinal))
                    ?? remoteAddresses[0];
            else
                addr = remoteAddresses.OrderBy(a => a.StartsWith("169.254.", StringComparison.Ordinal) ? 0 : 1).First();
            var got = addr.StartsWith("169.254.", StringComparison.Ordinal)
                ? (prefer is LinkKind.thunderbolt or LinkKind.usb ? prefer : LinkKind.ethernet)
                : LinkKind.wifi;
            var fell = prefer is not null && got != prefer;
            return new(addr, fell, got);
        }
        var (chosen, fellBack) = Select(routes, prefer);
        return new(chosen[0].Address, fellBack, chosen[0].Kind);
    }

    private const string LoopbackName = "Loopback Pseudo-Interface 1";

    private static uint? ParseIpv4(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        var parts = s.Split('.');
        if (parts.Length != 4) return null;
        uint v = 0;
        foreach (var p in parts)
        {
            if (!byte.TryParse(p, out var b)) return null;
            v = (v << 8) | b;
        }
        return v;
    }
}
