using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Afterscreen.Protocol;
using Zeroconf;

namespace Afterscreen.Sender.Session;

/// <summary>A receiver found on the network (Mac <c>DiscoveredReceiver</c>).</summary>
public sealed record DiscoveredReceiver(
    string Name, string Model, string Panel, int Port, string Host, IReadOnlyList<string> Addresses, string DeviceId)
{
    /// <summary>The address to connect to: the first IPv4 address (link-local 169.254.x.x for a cable), else the host name.</summary>
    public string Address => Addresses.FirstOrDefault() ?? Host;
}

/// <summary>
/// Mac <c>Discovery</c>: Bonjour (mDNS) browse for <c>_afterscreen._tcp</c>. The Receiver advertises a temporary port that changes
/// whenever it restarts, so the address is looked up on every scan instead of being typed in. TXT keys: model, panel, id (the
/// receiver's lasting identity). The list is rescanned every few seconds; a receiver leaves it after two scans without an answer
/// (one lost multicast reply must not make it flicker).
/// </summary>
public sealed class Discovery : IDisposable
{
    public static readonly string Protocol = AfterscreenProtocol.BonjourType + ".local.";

    private readonly CancellationTokenSource _cts = new();
    private readonly Dictionary<string, (DiscoveredReceiver Receiver, int Misses)> _known = new();
    private readonly object _lock = new();
    private Task? _loop;
    private IReadOnlyList<DiscoveredReceiver> _list = Array.Empty<DiscoveredReceiver>();

    /// <summary>Raised from a background thread whenever the list changes.</summary>
    public event Action<IReadOnlyList<DiscoveredReceiver>>? Changed;

    public IReadOnlyList<DiscoveredReceiver> Receivers
    {
        get { lock (_lock) return _list; }
    }

    public void Start()
    {
        _loop ??= Task.Run(() => Loop(_cts.Token));
    }

    /// <summary>Scan once now (after a refused connection: a restart moves the port without any event).</summary>
    public async Task<IReadOnlyList<DiscoveredReceiver>> ScanNowAsync(CancellationToken ct = default)
    {
        await ScanOnce(ct).ConfigureAwait(false);
        return Receivers;
    }

    /// <summary>Mac Discovery.retryDelay: 2 s, doubling to 15 s.</summary>
    public static TimeSpan RetryDelay(int failures) => TimeSpan.FromSeconds(Math.Min(15, 2 * Math.Pow(2, failures)));

    /// <summary>Normal pace of the rescan while receivers are being found.</summary>
    public static readonly TimeSpan ScanInterval = TimeSpan.FromSeconds(3);

    /// <summary>
    /// Rescans every <see cref="ScanInterval"/> while something answers. A scan that finds nothing (the receiver is off, or a scan failed)
    /// is retried on the Mac's backoff - 2 s, doubling to 15 s - so an absent receiver is not hammered with queries; the first answer
    /// returns to the normal pace.
    /// </summary>
    private async Task Loop(CancellationToken ct)
    {
        var failures = 0;
        while (!ct.IsCancellationRequested)
        {
            var found = false;
            try { found = await ScanOnce(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { Console.WriteLine("[discovery] " + ex.Message); }
            failures = found ? 0 : failures + 1;
            var delay = found ? ScanInterval : RetryDelay(failures - 1);
            try { await Task.Delay(delay, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    /// <summary>
    /// One scan on every usable network adapter separately: the receiver answers on each link with that link's address (a cable's 169.254.x.x
    /// next to the LAN address), and a single multicast query would only learn one of them. Results are merged per receiver name.
    /// </summary>
    private async Task<bool> ScanOnce(CancellationToken ct)
    {
        var nics = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.SupportsMulticast
                && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel
                && n.GetIPProperties().UnicastAddresses.Any(a => a.Address.AddressFamily == AddressFamily.InterNetwork))
            .ToList();
        var tasks = nics.Select(async nic =>
        {
            try
            {
                return await ZeroconfResolver.ResolveAsync(Protocol, scanTime: TimeSpan.FromSeconds(2), retries: 2, retryDelayMilliseconds: 600,
                    cancellationToken: ct, netInterfacesToSendRequestOn: new[] { nic }).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { throw; }
            catch { return new List<IZeroconfHost>(); }
        }).ToList();
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);

        // Merge the answers of all adapters per receiver
        var merged = new Dictionary<string, DiscoveredReceiver>();
        foreach (var host in results.SelectMany(r => r))
        {
            var r = Convert(host);
            if (r is null) continue;
            merged[r.Name] = merged.TryGetValue(r.Name, out var have)
                ? have with { Addresses = have.Addresses.Concat(r.Addresses).Distinct().OrderBy(AddressRank).ToList() }
                : r;
        }

        var seen = new HashSet<string>(merged.Keys);
        lock (_lock)
        {
            foreach (var r in merged.Values) _known[r.Name] = (r, 0);
            foreach (var key in _known.Keys.ToList())
            {
                if (seen.Contains(key)) continue;
                var (rec, misses) = _known[key];
                if (misses + 1 >= 2) _known.Remove(key); else _known[key] = (rec, misses + 1);
            }
            var next = _known.Values.Select(v => v.Receiver).OrderBy(r => r.Name, StringComparer.Ordinal).ToList();
            if (next.SequenceEqual(_list, new ReceiverComparer())) return merged.Count > 0;
            _list = next;
        }
        Changed?.Invoke(Receivers);
        return merged.Count > 0;
    }

    /// <summary>A cable's link-local address first (the fastest link), then the rest.</summary>
    private static int AddressRank(string a) => a.StartsWith("169.254.") ? 0 : 1;

    private static DiscoveredReceiver? Convert(IZeroconfHost host)
    {
        // A host record can carry its other services too (ssh on port 22, ...): pick the Afterscreen one by its service name
        var service = host.Services.FirstOrDefault(kv => kv.Key.Contains(AfterscreenProtocol.BonjourType, StringComparison.OrdinalIgnoreCase)).Value;
        if (service is null || service.Port <= 0) return null;
        var props = service.Properties.FirstOrDefault() ?? new Dictionary<string, string>();
        string Txt(string k) => props.TryGetValue(k, out var v) ? v : "";
        // IPv4 only: a link-local IPv6 address needs a scope id; the receiver listens on both
        var addresses = host.IPAddresses
            .Where(a => IPAddress.TryParse(a, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork)
            .OrderBy(a => a.StartsWith("169.254.") ? 0 : 1)       // a cable first, as the Mac prefers the fastest link
            .ToList();
        if (addresses.Count == 0) return null;
        var name = host.DisplayName;
        // DisplayName can be "Name._afterscreen._tcp.local."
        var cut = name.IndexOf("._afterscreen", StringComparison.OrdinalIgnoreCase);
        if (cut > 0) name = name[..cut];
        return new DiscoveredReceiver(name, Txt("model"), Txt("panel"), service.Port, host.Id ?? "", addresses, Txt("id"));
    }

    private sealed class ReceiverComparer : IEqualityComparer<DiscoveredReceiver>
    {
        public bool Equals(DiscoveredReceiver? a, DiscoveredReceiver? b) =>
            a is not null && b is not null && a.Name == b.Name && a.Port == b.Port && a.Model == b.Model && a.Panel == b.Panel
            && a.DeviceId == b.DeviceId && a.Addresses.SequenceEqual(b.Addresses);
        public int GetHashCode(DiscoveredReceiver r) => HashCode.Combine(r.Name, r.Port);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}
