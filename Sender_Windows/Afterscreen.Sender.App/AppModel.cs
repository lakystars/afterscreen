using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Session;

namespace Afterscreen.Sender.App;

/// <summary>
/// Mac <c>AppModel</c>: owns the settings and the running <see cref="SenderSession"/>, and gives the popover a
/// snapshot to draw. All members are used from the UI thread; session callbacks are marshalled by the caller of
/// <see cref="Changed"/>.
/// </summary>
public sealed class AppModel
{
    public AppSettings Settings { get; } = AppSettings.Load();
    public FilePairingStore Store { get; } = new(AppSettings.StoreDir);

    public SenderSnapshot? Snapshot { get; private set; }
    public bool IsActive => _cts is not null;
    public bool IsStreaming => Snapshot is { Phase: SessionPhase.Streaming };
    public ReceiverEntry? Active { get; private set; }
    public string? LastMessage { get; private set; }
    public bool ShowsSettings { get; set; }

    /// <summary>Last 60 one-second samples, newest last (the link chart).</summary>
    public List<double> ThroughputHistory { get; } = new();
    public List<double> LatencyHistory { get; } = new();

    public event Action? Changed;

    private CancellationTokenSource? _cts;
    private SenderSession? _session;
    private TaskCompletionSource<string>? _firstCode;
    private object? _lastStats;

    private readonly Discovery _discovery = new();
    private readonly UpdateChecker _updates = new();
    private string? _latestTag;
    /// <summary>Mac AutoConnect.paused: user hit Disconnect; cleared when that receiver leaves the list.</summary>
    private bool _autoPaused;
    private int _autoFailures;
    private CancellationTokenSource? _autoRetry;
    private readonly SystemSleep _systemSleep = new();
    /// <summary>Mac <c>screensAsleep</c>: PC suspending or display sleep; blocks auto-connect until wake.</summary>
    private bool _screensAsleep;
    /// <summary>Mac <c>restart</c>: reconnect this entry after the current session ends (resolution / role).</summary>
    private ReceiverEntry? _restartTarget;
    /// <summary>Mac <c>fasterLink</c>: backoff state for automatic mid-session upgrades.</summary>
    private FasterLinkPolicy.Tries? _fasterLink;
    private CancellationTokenSource? _fasterLinkRetry;

    /// <summary>
    /// What the receivers list shows (Mac: the receivers Bonjour finds): every discovered receiver at its current address and port,
    /// then saved entries that are not on the network now (manual addresses, receivers switched off).
    /// </summary>
    public IReadOnlyList<ReceiverEntry> VisibleReceivers
    {
        get
        {
            var list = new List<ReceiverEntry>();
            foreach (var d in _discovery.Receivers)
            {
                var saved = FindSaved(d);
                list.Add(saved ?? new ReceiverEntry
                {
                    Name = d.Name, Host = d.Address, Port = d.Port, Model = d.Model, Panel = d.Panel, DeviceId = d.DeviceId,
                });
                list[^1].Found = true;
            }
            foreach (var s in Settings.Receivers)
                if (!list.Contains(s)) { s.Found = false; list.Add(s); }
            return list;
        }
    }

    /// <summary>Prefer lasting TXT <c>id</c>, then name, then address (two receivers can share a display name).</summary>
    private ReceiverEntry? FindSaved(DiscoveredReceiver d)
    {
        if (d.DeviceId.Length > 0)
        {
            var byId = Settings.Receivers.FirstOrDefault(r => r.DeviceId.Length > 0 && r.DeviceId == d.DeviceId);
            if (byId is not null) return byId;
        }
        return Settings.Receivers.FirstOrDefault(r =>
            (r.Name.Length > 0 && r.Name == d.Name) || d.Addresses.Contains(r.Host));
    }

    /// <summary>A saved receiver that was found again: its address and port follow the network (the Receiver picks a new port on every start).</summary>
    private void HealSaved()
    {
        var changed = false;
        foreach (var d in _discovery.Receivers)
        {
            if (FindSaved(d) is not { } r) continue;
            if (r.Host != d.Address || r.Port != d.Port || r.Name != d.Name || r.Model != d.Model || r.Panel != d.Panel
                || (d.DeviceId.Length > 0 && r.DeviceId != d.DeviceId))
            {
                r.Host = d.Address; r.Port = d.Port; r.Name = d.Name; r.Model = d.Model; r.Panel = d.Panel;
                if (d.DeviceId.Length > 0) r.DeviceId = d.DeviceId;
                changed = true;
            }
        }
        if (changed) Settings.Save();
    }

    public AppModel()
    {
        _discovery.Changed += _list =>
        {
            HealSaved();
            ClearAutoPauseIfGone();
            Changed?.Invoke();
            var disp = System.Windows.Application.Current?.Dispatcher;
            if (disp is not null)
            {
                disp.BeginInvoke(new Action(ConsiderAutoConnect));
                disp.BeginInvoke(new Action(ConsiderFasterLink));
            }
            else
            {
                ConsiderAutoConnect();
                ConsiderFasterLink();
            }
        };
        _discovery.Start();
        L10n.Korean = Settings.Language switch
        {
            "ko" => true,
            "en" => false,
            _ => System.Globalization.CultureInfo.InstalledUICulture.TwoLetterISOLanguageName == "ko",
        };
        _systemSleep.OnSuspend = WillSleep;
        _systemSleep.OnResume = ScreensWoke;
        _pendingCodeTimer = new Timer(_ => PollPendingCode(), null, 1000, 1000);
    }

    private readonly Timer _pendingCodeTimer;

    /// <summary>
    /// Dev: a 6-digit code written to pending-code.txt in the settings folder is submitted like a typed one, so a
    /// session started with --connect can be paired without the window. The file is consumed.
    /// </summary>
    private void PollPendingCode()
    {
        if (!IsActive) return;
        var path = Path.Combine(AppSettings.StoreDir, "pending-code.txt");
        string code;
        try
        {
            if (!File.Exists(path)) return;
            code = File.ReadAllText(path).Trim();
            File.Delete(path);
        }
        catch { return; }
        if (code.Length != 6 || !code.All(char.IsAsciiDigit)) return;
        var disp = System.Windows.Application.Current?.Dispatcher;
        if (disp is not null) _ = disp.BeginInvoke(new Action(() => SubmitPairingCode(code)));
        else SubmitPairingCode(code);
    }

    /// <summary>Mac <c>willSleep</c>: PowerOff (no EndPower request), end session; do not auto-pause.</summary>
    private void WillSleep()
    {
        _screensAsleep = true;
        _autoRetry?.Cancel();
        var session = _session;
        if (session is { Snapshot.Phase: SessionPhase.Streaming, TestMode: false })
        {
            try
            {
                var reason = L10n.T($"{MachineName} went to sleep", $"{MachineName}이(가) 잠자기에 들어갔습니다");
                session.SendPowerOff(reason, null);
                Thread.Sleep(200); // Mac waits up to 2 s; Windows cannot hold suspend — brief flush only
            }
            catch { /* best-effort before suspend */ }
        }
        try { _cts?.Cancel(); } catch { /* already gone */ }
    }

    /// <summary>Mac <c>screensWoke</c>: after ~2 s, auto-connect if still idle.</summary>
    private void ScreensWoke()
    {
        _screensAsleep = false;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(2000).ConfigureAwait(false); }
            catch { return; }
            if (_screensAsleep || _cts is not null) return;
            var disp = System.Windows.Application.Current?.Dispatcher;
            if (disp is not null) _ = disp.BeginInvoke(new Action(ConsiderAutoConnect));
            else ConsiderAutoConnect();
        });
    }

    public void SetAutoConnect(bool on)
    {
        Settings.AutoConnect = on;
        Settings.Save();
        if (on) { _autoPaused = false; _autoFailures = 0; ConsiderAutoConnect(); }
        Changed?.Invoke();
    }

    /// <summary>
    /// Mac <c>considerAutoConnect</c>: only when idle, auto-connect is on, and the last receiver is listed
    /// without needing a pairing code (already paired, or a link-local cable address).
    /// </summary>
    public void ConsiderAutoConnect()
    {
        if (_cts is not null || !Settings.AutoConnect || _autoPaused || _screensAsleep) return;
        var d = PickAutoTarget();
        if (d is null) return;
        var entry = FindSaved(d) ?? new ReceiverEntry
        {
            Name = d.Name, Host = d.Address, Port = d.Port, Model = d.Model, Panel = d.Panel, DeviceId = d.DeviceId,
        };
        if (!CanConnectWithoutCode(entry, d)) return;
        Connect(entry);
    }

    private DiscoveredReceiver? PickAutoTarget()
    {
        var list = _discovery.Receivers;
        if (Settings.LastReceiverId is { Length: > 0 } id)
        {
            var byId = list.FirstOrDefault(d => d.DeviceId == id);
            if (byId is not null) return byId;
        }
        if (Settings.LastReceiverName is { Length: > 0 } name)
        {
            var byName = list.FirstOrDefault(d => d.Name == name);
            if (byName is not null) return byName;
        }
        if (Settings.LastReceiver is { Length: > 0 } last)
        {
            var host = last;
            var colon = last.LastIndexOf(':');
            if (colon > 0 && last.Count(c => c == ':') == 1) host = last[..colon];
            return list.FirstOrDefault(d => d.Addresses.Contains(host) || d.Address == host);
        }
        return null;
    }

    /// <summary>Mac <c>connectsWithoutCode</c>: paired, or Thunderbolt/USB/loopback (Ethernet still needs a code).</summary>
    private bool CanConnectWithoutCode(ReceiverEntry entry, DiscoveredReceiver d)
    {
        if (IsPaired(entry)) return true;
        var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
        var route = RoutePlanner.PickDetailed(local, d.Addresses, Settings.PreferredLink).Got;
        return FasterLinkPolicy.ConnectsWithoutCode(paired: false, route);
    }

    private void ClearAutoPauseIfGone()
    {
        if (!_autoPaused) return;
        if (PickAutoTarget() is null) _autoPaused = false;
    }

    private void ScheduleAutoRetry()
    {
        if (!Settings.AutoConnect || _autoPaused || _screensAsleep) return;
        _autoRetry?.Cancel();
        _autoRetry = new CancellationTokenSource();
        var delay = TimeSpan.FromSeconds(Math.Min(60, 3 * Math.Pow(2, _autoFailures)));
        _autoFailures++;
        var ct = _autoRetry.Token;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(delay, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            var disp = System.Windows.Application.Current?.Dispatcher;
            if (disp is not null) _ = disp.BeginInvoke(new Action(ConsiderAutoConnect));
            else ConsiderAutoConnect();
        }, ct);
    }

    /// <summary>The receiver's own name ("Dev's iMac"), used in labels as the Mac popover does; the header shows the marketing name.</summary>
    public string ReceiverName => Snapshot?.Peer?.Name is { Length: > 0 } m ? m
        : Active?.Name is { Length: > 0 } a ? a : L10n.T("Receiver", "수신기");

    public string MachineName => Environment.MachineName;

    /// <summary>Newer release for this PC or the connected receiver (Mac <c>availableUpdate</c>).</summary>
    public AvailableUpdate? AvailableUpdate
    {
        get
        {
            if (_latestTag is null) return null;
            var receiver = Snapshot?.Peer is { } p ? (p.AppVersion ?? "1.0.0") : null;
            return UpdateChecker.Update(_latestTag, AppVersion.Current, receiver);
        }
    }

    /// <summary>From the app only: wire GitHub polling to <see cref="Settings.ChecksUpdates"/>.</summary>
    public void StartUpdateChecks()
    {
        AppVersion.Current ??= ReadInstalledVersion();
        _updates.OnTag = tag =>
        {
            if (_latestTag == tag) return;
            _latestTag = tag;
            Changed?.Invoke();
        };
        ApplyUpdateChecks();
    }

    public void SetChecksUpdates(bool on)
    {
        Settings.ChecksUpdates = on;
        Settings.Save();
        ApplyUpdateChecks();
        Changed?.Invoke();
    }

    private void ApplyUpdateChecks()
    {
        if (Settings.ChecksUpdates) _updates.Start();
        else
        {
            _updates.Stop();
            _latestTag = null;
        }
    }

    private static string? ReadInstalledVersion()
    {
        try
        {
            var v = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version;
            if (v is null || (v.Major == 0 && v.Minor == 0 && v.Build == 0)) return null;
            return $"{v.Major}.{v.Minor}.{v.Build}";
        }
        catch { return null; }
    }

    public bool IsPaired(ReceiverEntry r) =>
        (r.DeviceId.Length > 0 && Store.Pairs.Any(p => p.Id == r.DeviceId))
        || Store.Pairs.Any(p => p.Name == r.Name && r.Name.Length > 0);

    public IReadOnlyList<(string Id, string Name)> Pairs => Store.Pairs;

    public void RemovePairing(string id) => Store.Remove(id);

    // ---- receivers -------------------------------------------------------------------------------------------------

    /// <summary>Accepts "host" or "host:port"; returns null when it does not parse.</summary>
    public ReceiverEntry? AddReceiver(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return null;
        var host = text;
        var port = 50206;
        var colon = text.LastIndexOf(':');
        if (colon > 0 && text.Count(c => c == ':') == 1)
        {
            host = text[..colon];
            if (!int.TryParse(text[(colon + 1)..], out port) || port is < 1 or > 65535) return null;
        }
        if (host.Length == 0) return null;
        var existing = Settings.Receivers.FirstOrDefault(r => r.Host == host && r.Port == port);
        if (existing is not null) return existing;
        var entry = new ReceiverEntry { Name = host, Host = host, Port = port };
        Settings.Receivers.Add(entry);
        Settings.Save();
        Changed?.Invoke();
        return entry;
    }

    public void RemoveReceiver(ReceiverEntry r)
    {
        Settings.Receivers.Remove(r);
        Settings.Save();
        Changed?.Invoke();
    }

    // ---- session ---------------------------------------------------------------------------------------------------

    /// <summary>Mac "Test": a quality test run instead of mirroring (the session streams a test pattern).</summary>
    public bool IsTesting { get; private set; }
    /// <summary>The last quality test's progress / results; kept after the session ends so the idle page can show it.</summary>
    public QualityTest.Report? TestReport { get; private set; }

    public void RunQualityTest(ReceiverEntry r) => Connect(r, test: true);

    public void SetPreferredLink(string link)
    {
        Settings.PreferredLink = RoutePlanner.ParsePreferred(link) is not null ? link : "auto";
        Settings.Save();
        Changed?.Invoke();
        if (Settings.PreferredLink == "auto")
        {
            ConsiderFasterLink();
            return;
        }
        // Chosen link: seamless handover if possible, else relink.
        if (_session is not { } session || IsTesting || session.IsHandingOver) return;
        if (Snapshot is not { Phase: SessionPhase.Streaming } || Active is null) return;
        if (RoutePlanner.ParsePreferred(Settings.PreferredLink) is not { } kind) return;
        if (Snapshot.Link == kind) return;
        if (_discovery.Receivers.FirstOrDefault(d =>
                (Active.DeviceId.Length > 0 && d.DeviceId == Active.DeviceId)
                || d.Name == Active.Name
                || d.Addresses.Contains(Active.Host)) is not { } d) return;
        var host = RoutePlanner.PickAddress(d.Addresses, Settings.PreferredLink);
        if (host.Length == 0) return;
        var name = FasterLinkPolicy.LinkName(kind);
        if (session.TryHandover(host, kind, outcome => HandedOver(outcome, kind, d, faster: false)))
            return;
        Active.Host = host;
        RestartSession(L10n.T($"Switching to {name}", $"{name}(으)로 바꾸는 중"));
    }

    /// <summary>Mac <c>considerFasterLink</c>: when Automatic, move to a faster planned route mid-session.</summary>
    private void ConsiderFasterLink()
    {
        if (Settings.PreferredLink != "auto") return;
        if (_session is not { } session || IsTesting || session.IsHandingOver) return;
        if (Snapshot is not { Phase: SessionPhase.Streaming, Link: { } current } || Active is null) return;
        if (_discovery.Receivers.FirstOrDefault(d =>
                (Active.DeviceId.Length > 0 && d.DeviceId == Active.DeviceId)
                || d.Name == Active.Name
                || d.Addresses.Contains(Active.Host)) is not { } d) return;

        var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
        var remote = d.Addresses.Select(a => new RemoteAddress(a)).ToList();
        var routes = RoutePlanner.Plan(local, remote);
        var available = RoutePlanner.Kinds(routes);
        var faster = RoutePlanner.Upgrade(current, available);
        if (faster is null)
        {
            if (RoutePlanner.BelowFastest(current)) ScheduleFasterLink(15);
            return;
        }
        var now = Environment.TickCount64 / 1000.0;
        switch (FasterLinkPolicy.Try(_fasterLink, d.Name, faster.Value, now, session.CanHandOver(faster.Value)))
        {
            case FasterLinkPolicy.Decision.Never:
                ScheduleFasterLink(15);
                return;
            case FasterLinkPolicy.Decision.Wait(var seconds):
                ScheduleFasterLink(seconds);
                return;
            case FasterLinkPolicy.Decision.Go(var next):
                _fasterLink = next;
                break;
        }
        var host = routes.FirstOrDefault(r => r.Kind == faster.Value).Address;
        if (string.IsNullOrEmpty(host)) return;
        if (session.TryHandover(host, faster.Value, outcome => HandedOver(outcome, faster.Value, d, faster: true)))
            return;
        Active.Host = host;
        RestartSession(L10n.T(
            $"Switching to the faster {FasterLinkPolicy.LinkName(faster)}",
            $"더 빠른 {FasterLinkPolicy.LinkName(faster)}(으)로 바꾸는 중"));
    }

    private void HandedOver(SenderSession.HandoverOutcome outcome, LinkKind kind, DiscoveredReceiver receiver, bool faster)
    {
        var name = FasterLinkPolicy.LinkName(kind);
        var disp = System.Windows.Application.Current?.Dispatcher;
        void Apply()
        {
            switch (outcome)
            {
                case SenderSession.HandoverOutcome.Switched:
                    LastMessage = faster
                        ? L10n.T(FasterLinkPolicy.FasterOutcome(kind, kind),
                            $"더 빠른 {name}(으)로 바꿨습니다")
                        : L10n.T($"Switched to {name}", $"{name}(으)로 바꿨습니다");
                    if (Active is not null)
                        Active.Host = RoutePlanner.PickAddress(receiver.Addresses, RoutePlanner.PreferKey(kind));
                    Changed?.Invoke();
                    ConsiderFasterLink();
                    break;
                case SenderSession.HandoverOutcome.Stayed when faster:
                    LastMessage = L10n.T(
                        $"{name} did not take over; staying on {FasterLinkPolicy.LinkName(Snapshot?.Link)}",
                        $"{name}(으)로 넘기지 못해 {FasterLinkPolicy.LinkName(Snapshot?.Link)}(으)로 계속 보냅니다");
                    Changed?.Invoke();
                    ConsiderFasterLink();
                    break;
                case SenderSession.HandoverOutcome.Stayed:
                    if (Active is null || _session is null) return;
                    Active.Host = RoutePlanner.PickAddress(receiver.Addresses, RoutePlanner.PreferKey(kind));
                    RestartSession(L10n.T($"Switching to {name}", $"{name}(으)로 바꾸는 중"));
                    break;
                case SenderSession.HandoverOutcome.Lost:
                    if (faster && _fasterLink is { Kind: var k } t && k == kind && t.Receiver == receiver.Name)
                        _fasterLink.Reconnects++;
                    if (Active is not null)
                    {
                        Active.Host = RoutePlanner.PickAddress(receiver.Addresses, RoutePlanner.PreferKey(kind));
                        RestartSession(L10n.T($"Switching to {name}", $"{name}(으)로 바꾸는 중"));
                    }
                    break;
            }
        }
        if (disp is not null) disp.BeginInvoke(new Action(Apply));
        else Apply();
    }

    private void ScheduleFasterLink(double seconds)
    {
        _fasterLinkRetry?.Cancel();
        var cts = new CancellationTokenSource();
        _fasterLinkRetry = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, seconds)), cts.Token).ConfigureAwait(false);
                var disp = System.Windows.Application.Current?.Dispatcher;
                if (disp is not null) _ = disp.BeginInvoke(new Action(ConsiderFasterLink));
                else ConsiderFasterLink();
            }
            catch (OperationCanceledException) { /* superseded */ }
        });
    }

    /// <summary>Mac <c>model.links[receiver]</c>: planned kinds that currently reach this receiver.</summary>
    public IReadOnlyList<LinkKind> AnsweringLinks(ReceiverEntry? r = null)
    {
        r ??= Active;
        if (r is null) return Array.Empty<LinkKind>();
        var d = _discovery.Receivers.FirstOrDefault(x =>
            (r.DeviceId.Length > 0 && x.DeviceId == r.DeviceId)
            || x.Name == r.Name
            || x.Addresses.Contains(r.Host));
        if (d is null) return Array.Empty<LinkKind>();
        var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
        var remote = d.Addresses.Select(a => new RemoteAddress(a)).ToList();
        return RoutePlanner.Kinds(RoutePlanner.Plan(local, remote));
    }

    /// <summary>Mac link pin via <see cref="RoutePlanner"/> (subnet match + prefer; cable-first fallback).</summary>
    private string PickAddress(DiscoveredReceiver d, string preferred)
    {
        var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
        var pick = RoutePlanner.PickDetailed(local, d.Addresses, preferred);
        if (pick.Address.Length == 0) return d.Address;
        if (pick.FellBack && RoutePlanner.ParsePreferred(preferred) is { } wanted)
        {
            LastMessage = L10n.T(
                FasterLinkPolicy.FasterOutcome(wanted, pick.Got),
                $"{FasterLinkPolicy.LinkName(wanted)}(으)로 연결하지 못해 {FasterLinkPolicy.LinkName(pick.Got)}(으)로 연결합니다");
            _pendingMissingLink = wanted;
        }
        else _pendingMissingLink = null;
        return pick.Address;
    }

    /// <summary>Set on connect when PreferredLink fell back; applied to the session snapshot once streaming.</summary>
    private LinkKind? _pendingMissingLink;

    public void Connect(ReceiverEntry r, bool test = false)
    {
        if (_cts is not null) return;
        if (_discovery.Receivers.FirstOrDefault(d => d.Name == r.Name || d.Addresses.Contains(r.Host)) is { } fresh)
        {
            r.Host = PickAddress(fresh, Settings.PreferredLink);
            r.Port = fresh.Port;      // the port may have changed since the list was drawn
            if (Settings.Receivers.Contains(r)) Settings.Save();
        }
        IsTesting = test;
        if (test) TestReport = null;
        LastMessage = null;
        Active = r;
        Snapshot = null;
        ThroughputHistory.Clear();
        LatencyHistory.Clear();
        ShowsSettings = false;
        if (!Settings.Receivers.Contains(r) && !Settings.Receivers.Any(s => s.Name == r.Name && r.Name.Length > 0))
            Settings.Receivers.Add(r);                          // remembered once used
        Settings.LastReceiver = r.Address;
        Settings.LastReceiverName = r.Name;
        if (r.DeviceId.Length > 0) Settings.LastReceiverId = r.DeviceId;
        Settings.Save();
        _autoPaused = false;
        _autoFailures = 0;
        _autoRetry?.Cancel();
        // Capture env (AFTERSCREEN_OUTPUT) is applied in RunSessions after VDD activate, so Extend can see MTT.
        _cts = new CancellationTokenSource();
        _firstCode = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var ct = _cts.Token;
        _ = Task.Run(() => RunSessions(r, ct));
        Changed?.Invoke();
    }

    /// <summary>
    /// Mac <c>disconnect(powerReceiver:)</c>. Always PowerOff while streaming (Mac <c>close</c>);
    /// <paramref name="powerReceiver"/> selects <see cref="AppSettings.EndPower"/> (keepOn → null).
    /// </summary>
    public void Disconnect(bool powerReceiver = false)
    {
        _autoPaused = true;                                  // Mac AutoConnect.userDisconnected
        _autoRetry?.Cancel();
        var session = _session;
        // Mac close: PowerOff only while streaming a display session; else stop immediately.
        if (session is { Snapshot.Phase: SessionPhase.Streaming, TestMode: false })
        {
            var power = powerReceiver ? EndPowerRequest(Settings.EndPower) : null;
            _ = Task.Run(async () =>
            {
                try
                {
                    session.SendPowerOff("Disconnect", power);
                    await Task.Delay(3000).ConfigureAwait(false); // Mac: ≤0.85 s black; silent receiver ends by 3 s
                }
                catch { /* ignore */ }
                try { _cts?.Cancel(); } catch { /* already gone */ }
            });
            return;
        }
        try { _cts?.Cancel(); } catch { /* already gone */ }
    }

    public void SetEndPower(string value)
    {
        Settings.EndPower = value is "sleep" or "shutDown" ? value : "keepOn";
        Settings.Save();
        Changed?.Invoke();
    }

    private static ReceiverPower? EndPowerRequest(string endPower) => endPower switch
    {
        "sleep" => ReceiverPower.sleep,
        "shutDown" => ReceiverPower.shutDown,
        _ => null, // keepOn: send no power request
    };

    /// <summary>Receiver 8-bit step smoothing (Mac setDeband).</summary>
    public void SetDeband(int level)
    {
        Settings.Deband = level;
        Settings.Save();
        _session?.SetDeband((Deband)Math.Clamp(level, 0, 3));
    }

    /// <summary>Mac changeReceiver: edits the connected receiver's own settings.</summary>
    public void ChangeReceiver(ReceiverOptionsChange change) => _session?.SetReceiverOptions(change);

    /// <summary>Mac "Play on receiver": session only (idle has no receiver to play on), so it is not stored.</summary>
    public bool Sound { get; private set; }

    public void SetSound(bool on)
    {
        Sound = on;
        _session?.SetSound(on);
    }

    /// <summary>Receiver brightness slider 0…1 when not following the PC panel.</summary>
    public double Brightness
    {
        get => Settings.ReceiverBrightness;
        private set => Settings.ReceiverBrightness = Math.Clamp(value, 0, 1);
    }

    /// <summary>Mac <c>brightnessFollows</c>.</summary>
    public bool BrightnessFollows
    {
        get => Settings.BrightnessFollows;
        private set => Settings.BrightnessFollows = value;
    }

    /// <summary>Latest PC panel level from the session snapshot (null when unreadable).</summary>
    public double? PcBrightness => Snapshot?.MacBrightness ?? Capture.PanelBrightness.TryRead();

    public void SetBrightnessFollows(bool on)
    {
        if (!on && BrightnessFollows && PcBrightness is { } level)
            Brightness = level;
        BrightnessFollows = on;
        Settings.Save();
        ApplyBrightnessToSession();
        Changed?.Invoke();
    }

    public void SetReceiverBrightness(double level)
    {
        Brightness = level;
        Settings.Save();
        if (!BrightnessFollows)
            _session?.SetReceiverBrightness(Brightness);
        Changed?.Invoke();
    }

    /// <summary>Mac <c>setMacBrightness</c>: moves the PC panel while following.</summary>
    public void SetPcBrightness(double level)
    {
        level = Math.Clamp(level, 0, 1);
        PanelBrightness.TrySet(level);
        if (_session?.Snapshot is { } s)
            s.MacBrightness = level;
        ApplyBrightnessToSession();
        Changed?.Invoke();
    }

    public double BrightnessOffsetForActive()
    {
        var id = ActiveReceiverId();
        return id is null ? 0 : Settings.BrightnessOffsets.GetValueOrDefault(id);
    }

    public void SetBrightnessOffset(double stops)
    {
        var id = ActiveReceiverId();
        if (id is null) return;
        stops = Protocol.BrightnessOffset.Snapped(stops);
        if (stops == 0) Settings.BrightnessOffsets.Remove(id);
        else Settings.BrightnessOffsets[id] = stops;
        Settings.Save();
        _session?.SetBrightnessOffsets(new Dictionary<string, double>(Settings.BrightnessOffsets));
        Changed?.Invoke();
    }

    private string? ActiveReceiverId()
    {
        var id = Snapshot?.Peer?.ReceiverID;
        if (id is { Length: > 0 }) return id;
        id = Active?.DeviceId;
        return id is { Length: > 0 } ? id : null;
    }

    private void ApplyBrightnessToSession()
    {
        var follow = BrightnessFollows && PanelBrightness.IsAvailable;
        if (_session is null) return;
        _session.SetBrightnessOffsets(new Dictionary<string, double>(Settings.BrightnessOffsets));
        _session.SetReceiverBrightness(follow ? null : Brightness);
    }

    private bool _flashBlocks;
    /// <summary>Mac flashBlocks: not stored; off when the app starts again.</summary>
    public bool FlashBlocks
    {
        get => _flashBlocks;
        set { _flashBlocks = value; if (_session is { } s) s.FlashBlocks = value; }
    }

    public void SubmitPairingCode(string code)
    {
        if (_firstCode is { Task.IsCompleted: false } first)
            first.TrySetResult(code);              // the session's CodeProvider is still waiting for the first code
        else
            _session?.SubmitPairingCode(code);     // after a wrong code
    }

    /// <summary>
    /// Mac "Use as": Mirror shows the main monitor, Extend streams the second (virtual) monitor. The capture reads
    /// AFTERSCREEN_OUTPUT when a session starts; an explicitly set variable wins.
    /// </summary>
    private void ApplyCaptureSettings()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("AFTERSCREEN_CODEC")))
            Environment.SetEnvironmentVariable("AFTERSCREEN_CODEC", "hevc");
        if (Environment.GetEnvironmentVariable("AFTERSCREEN_OUTPUT_USER") is not null) return;
        string spec = "primary";
        if (Settings.DisplayRole == "extend")
        {
            try
            {
                var outputs = DxgiCapture.ListOutputs();
                var second = outputs.FirstOrDefault(o => o.Attached && !o.IsPrimaryPosition);
                if (second is not null)
                    spec = outputs.ToList().IndexOf(second).ToString();
                else
                    LastMessage = L10n.T("No second monitor found; mirroring the main display. Add a virtual display first.",
                                         "보조 모니터를 찾지 못해 주 디스플레이를 복제합니다. 가상 디스플레이를 먼저 추가하세요.");
            }
            catch { /* fall back to the main monitor */ }
        }
        Environment.SetEnvironmentVariable("AFTERSCREEN_OUTPUT", spec);
    }

    private async Task RunSessions(ReceiverEntry r, CancellationToken ct)
    {
        string? message = null;
        try
        {
            // Session-scoped VDD: attach before picking the capture output (gated by SessionLifetimeEnabled).
            VirtualDisplayControl.ActivateForSession();
            ApplyCaptureSettings();
            for (var attempt = 1; attempt <= 6 && !ct.IsCancellationRequested; attempt++)
            {
                _firstCode = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
                var peerAddrs = _discovery.Receivers
                    .FirstOrDefault(d =>
                        (r.DeviceId.Length > 0 && d.DeviceId == r.DeviceId)
                        || d.Name == r.Name
                        || d.Addresses.Contains(r.Host))
                    ?.Addresses
                    ?? (IReadOnlyList<string>)new[] { r.Host };
                var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
                var pick = RoutePlanner.PickDetailed(local, peerAddrs, Settings.PreferredLink);
                var link = pick.Got
                    ?? (r.Host.StartsWith("169.254.", StringComparison.Ordinal) ? LinkKind.ethernet : LinkKind.wifi);
                if (pick.Address.Length > 0) r.Host = pick.Address;
                using var session = new SenderSession(r.Host, r.Port, SenderId(), Store, link)
                {
                    CodeProvider = () => _firstCode!.Task.GetAwaiter().GetResult(),
                    TestMode = IsTesting,
                    Sound = Sound,
                    StreamResolution = Settings.StreamResolution,
                    Deband = (Deband)Math.Clamp(Settings.Deband, 0, 3),
                    FlashBlocks = FlashBlocks,
                    OwnBrightness = BrightnessFollows && PanelBrightness.IsAvailable ? null : Brightness,
                    BrightnessOffsets = new Dictionary<string, double>(Settings.BrightnessOffsets),
                    PeerAddresses = peerAddrs,
                    PeerDeviceId = r.DeviceId.Length > 0 ? r.DeviceId : null,
                    PeerName = r.Name,
                    OnResume = (ok, _, to) =>
                    {
                        var disp = System.Windows.Application.Current?.Dispatcher;
                        var addrs = peerAddrs;
                        void Apply()
                        {
                            LastMessage = ok
                                ? L10n.T($"Resumed on {FasterLinkPolicy.LinkName(to)}",
                                    $"{FasterLinkPolicy.LinkName(to)}(으)로 이어 보냅니다")
                                : L10n.T("The link dropped and no other link took over",
                                    "링크가 끊겨 다른 링크로 잇지 못했습니다");
                            if (ok && Active is not null)
                                Active.Host = RoutePlanner.PickAddress(addrs, RoutePlanner.PreferKey(to));
                            Changed?.Invoke();
                        }
                        if (disp is not null) disp.BeginInvoke(new Action(Apply));
                        else Apply();
                    },
                };
                _session = session;
                session.OnUpdate += s =>
                {
                    var becameStreaming = s.Phase == SessionPhase.Streaming
                        && Snapshot?.Phase != SessionPhase.Streaming;
                    if (becameStreaming && _pendingMissingLink is { } miss)
                    {
                        s.MissingLink = miss;
                        _pendingMissingLink = null;
                    }
                    Snapshot = s;
                    if (s.Quality is { } q) TestReport = q;
                    if (s.Stats is { } st && !ReferenceEquals(st, _lastStats))
                    {
                        _lastStats = st;
                        Push(ThroughputHistory, st.ThroughputBitsPerSecond);
                        Push(LatencyHistory, st.LatencyMs ?? 0);
                    }
                    if (s.Peer is { } p && Active is { } a)
                    {
                        var id = p.ReceiverID ?? "";
                        if (a.Name != p.Name || a.Model != p.MarketingName || (id.Length > 0 && a.DeviceId != id))
                        {
                            a.Name = p.Name;
                            a.Model = p.MarketingName;
                            a.Panel = $"{p.PanelPixels.Width} × {p.PanelPixels.Height}";
                            if (id.Length > 0) a.DeviceId = id;
                            Settings.Save();
                        }
                    }
                    Changed?.Invoke();
                    // Once when streaming starts (Mac: also on link changes via Discovery.Changed).
                    if (becameStreaming)
                    {
                        var d = System.Windows.Application.Current?.Dispatcher;
                        if (d is not null) d.BeginInvoke(new Action(ConsiderFasterLink));
                        else ConsiderFasterLink();
                    }
                };
                try
                {
                    await session.RunAsync(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (System.Net.Sockets.SocketException) when (attempt == 1)
                {
                    // Refused: a restarted Receiver listens on a new port without any event. Look again and retry once there.
                    var found = await _discovery.ScanNowAsync(ct).ConfigureAwait(false);
                    var fresh = found.FirstOrDefault(d =>
                        (r.DeviceId.Length > 0 && d.DeviceId == r.DeviceId)
                        || d.Name == r.Name
                        || d.Addresses.Contains(r.Host));
                    if (fresh is null || (fresh.Port == r.Port && fresh.Address == r.Host)) throw;
                    r.Host = fresh.Address; r.Port = fresh.Port; r.Name = fresh.Name;
                    if (fresh.DeviceId.Length > 0) r.DeviceId = fresh.DeviceId;
                    if (Settings.Receivers.Contains(r)) Settings.Save();
                    continue;
                }
                var last = session.Snapshot;
                message = EndMessage(last);
                if (!last.WantRelink) break;
                await Task.Delay(400, ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { /* disconnect */ }
        catch (Exception ex)
        {
            message = ex.Message;
        }
        finally
        {
            _session = null;
            IsTesting = false;
            var old = _cts;
            _cts = null;
            old?.Dispose();
            LastMessage = message ?? LastMessage;
            Snapshot = null;
            VirtualDisplayControl.DeactivateForSession();
            Changed?.Invoke();
            if (_restartTarget is { } again)
            {
                _restartTarget = null;
                var disp = System.Windows.Application.Current?.Dispatcher;
                if (disp is not null) _ = disp.BeginInvoke(new Action(() => Connect(again)));
                else Connect(again);
            }
            else if (!_autoPaused) ScheduleAutoRetry();
        }
    }

    /// <summary>Mac <c>restart</c>: end without auto-pause, then reconnect the same receiver.</summary>
    private void RestartSession(string reason)
    {
        if (_cts is null || IsTesting || Active is null) return;
        LastMessage = reason;
        _restartTarget = Active;
        _autoPaused = false;
        try { _cts.Cancel(); } catch { /* already gone */ }
    }

    public void SetStreamResolution(string value)
    {
        Settings.StreamResolution = value is "panel" or "reduced" ? value : "auto";
        Settings.Save();
        if (IsActive)
            RestartSession(L10n.T("Changing the resolution", "해상도를 바꾸는 중"));
        Changed?.Invoke();
    }

    public void SetDisplayRole(string role)
    {
        Settings.DisplayRole = role == "extend" ? "extend" : "mirror";
        Settings.Save();
        if (IsActive)
            RestartSession(Settings.DisplayRole == "mirror"
                ? L10n.T("Switching to mirroring", "복제로 바꾸는 중")
                : L10n.T("Switching to extending", "확장으로 바꾸는 중"));
        Changed?.Invoke();
    }

    private static string? EndMessage(SenderSnapshot s) =>
        s.State is { Length: > 0 } st && !st.StartsWith("Streaming", StringComparison.Ordinal) ? st : null;

    private static void Push(List<double> list, double v)
    {
        list.Add(v);
        if (list.Count > 60) list.RemoveAt(0);
    }

    private static string SenderId()
    {
        var path = Path.Combine(AppSettings.StoreDir, "sender-id.txt");
        try
        {
            Directory.CreateDirectory(AppSettings.StoreDir);
            if (File.Exists(path))
            {
                var id = File.ReadAllText(path).Trim();
                if (id.Length > 0) return id;
            }
            var made = Guid.NewGuid().ToString("N");
            File.WriteAllText(path, made);
            return made;
        }
        catch { return Environment.MachineName; }
    }

    // ---- launch at login -------------------------------------------------------------------------------------------

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public bool LaunchAtLogin
    {
        get
        {
            try { using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue("Afterscreen") is not null; }
            catch { return false; }
        }
        set
        {
            try
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true);
                if (k is null) return;
                if (value) k.SetValue("Afterscreen", $"\"{Environment.ProcessPath}\"");
                else k.DeleteValue("Afterscreen", false);
            }
            catch { /* policy may forbid it */ }
        }
    }
}
