using Afterscreen.Protocol;
using Afterscreen.Sender.Encode;
using Afterscreen.Transport;

namespace Afterscreen.Sender.Session;

public sealed partial class SenderSession
{
    public enum HandoverOutcome
    {
        /// <summary>Frames flow on the new link.</summary>
        Switched,
        /// <summary>Still on the old link.</summary>
        Stayed,
        /// <summary>Session should relink / ended.</summary>
        Lost,
    }

    private sealed class HandoffState
    {
        public required LinkKind Kind;
        public required byte[] Secret;
        public required byte[] Nonce;
        public required TaskCompletionSource<HandoverOutcome> Done;
        public Connection? Connection;
        public byte[]? ReceiverNonce;
        public bool Proven;
        public bool Switching;
        public bool Resume;
        public double? Gbps;
        public TaskCompletionSource<double>? ProbeDone;
        public TaskCompletionSource? SwitchEcho;
        public Queue<(string Host, LinkKind Kind)> Alternates = new();
        public string? TryingHost;
    }

    private HandoffState? _handoff;
    private volatile bool _stopping;
    private static readonly TimeSpan HandoverTimeout = TimeSpan.FromSeconds(6);
    private static readonly TimeSpan ResumeTimeout = TimeSpan.FromSeconds(7);

    /// <summary>Other receiver addresses from Bonjour (for resume / handover). Includes the current host.</summary>
    public IReadOnlyList<string> PeerAddresses { get; set; } = Array.Empty<string>();

    /// <summary>Mac <c>onResume</c>: true when a lost link came back over another route.</summary>
    public Action<bool, LinkKind?, LinkKind>? OnResume { get; set; }

    public bool IsHandingOver => _handoff is not null;

    /// <summary>Streaming, not stopping, and the receiver offered a handover token.</summary>
    public bool CanResume =>
        !_stopping && !TestMode && Snapshot.Phase == SessionPhase.Streaming
        && Snapshot.Peer?.HandoverToken is not null
        && _handoff is not { Resume: true };

    /// <summary>Moving to <paramref name="kind"/> keeps the session without a reconnect.</summary>
    public bool CanHandOver(LinkKind kind)
    {
        if (_stopping || TestMode || Snapshot.Phase != SessionPhase.Streaming || _handoff is not null || _conn is null)
            return false;
        if (Snapshot.Peer?.HandoverToken is null) return false;
        if ((Snapshot.Config?.FrameRate ?? 0) > 60 && kind != LinkKind.thunderbolt) return false;
        var welcome = Snapshot.Peer;
        if (welcome.Auth is not null)
        {
            if (welcome.ReceiverID is null) return false;
            if (_store.Key(welcome.ReceiverID) is null) return false;
        }
        return true;
    }

    /// <summary>
    /// Prove a second connection, measure it, send Switchover, then move the stream.
    /// False when the session cannot hand over.
    /// </summary>
    public bool TryHandover(string host, LinkKind kind, Action<HandoverOutcome>? done = null)
    {
        if (!CanHandOver(kind) || Snapshot.Peer?.HandoverToken is not { } token) return false;
        var secret = HandoverSecret(token);
        var state = new HandoffState
        {
            Kind = kind,
            Secret = secret,
            Nonce = Pairing.Nonce(),
            Done = new TaskCompletionSource<HandoverOutcome>(TaskCreationOptions.RunContinuationsAsynchronously),
            TryingHost = host,
        };
        _handoff = state;
        _ = Task.Run(async () =>
        {
            var outcome = await RunHandoverAsync(host, state).ConfigureAwait(false);
            done?.Invoke(outcome);
        });
        return true;
    }

    private byte[] HandoverSecret(byte[] token)
    {
        byte[]? key = null;
        if (Snapshot.Peer?.Auth is not null && Snapshot.Peer.ReceiverID is { } id)
            key = _store.Key(id);
        return Handover.Secret(key, token);
    }

    /// <summary>Main connection closed without Bye — try resume over another address.</summary>
    private void ConnectionClosed(string reason)
    {
        if (_stopping || Snapshot.Phase == SessionPhase.Ended) return;
        if (CanResume) LinkLost(reason);
        else End("closed: " + reason);
    }

    /// <summary>Mac <c>linkLost</c>: keep encoder/capture; prove another route within <see cref="ResumeTimeout"/>.</summary>
    private void LinkLost(string reason)
    {
        if (Snapshot.Peer?.HandoverToken is not { } token) { End("closed: " + reason); return; }
        if (Snapshot.Peer.Auth is not null && Snapshot.Peer.ReceiverID is { } id && _store.Key(id) is null)
        {
            End("closed: " + reason);
            return;
        }

        var from = _linkKind;
        var old = _conn;
        if (old is not null)
        {
            old.OnClose = null;
            old.OnMessage = null;
            try { old.Dispose(); } catch { /* ignore */ }
        }
        _conn = null;

        // Cancel an in-flight non-resume handover.
        if (_handoff is { Resume: false } cancelled)
        {
            try { cancelled.Connection?.Dispose(); } catch { /* ignore */ }
            cancelled.Done.TrySetResult(HandoverOutcome.Stayed);
            _handoff = null;
        }

        var alternates = BuildResumeAlternates(_host, _linkKind);
        if (alternates.Count == 0)
        {
            End(L10nResumeFailed());
            return;
        }

        var first = alternates.Dequeue();
        var state = new HandoffState
        {
            Kind = first.Kind,
            Secret = HandoverSecret(token),
            Nonce = Pairing.Nonce(),
            Done = new TaskCompletionSource<HandoverOutcome>(TaskCreationOptions.RunContinuationsAsynchronously),
            Resume = true,
            Alternates = alternates,
            TryingHost = first.Host,
        };
        _handoff = state;
        Snapshot.State = "Link lost; continuing over another";
        Publish();
        Console.WriteLine($"[handover] link lost ({reason}), resuming via {first.Host} ({first.Kind})");

        _ = Task.Run(async () =>
        {
            using var overall = new CancellationTokenSource(ResumeTimeout);
            HandoverOutcome outcome;
            try
            {
                outcome = await RunHandoverAsync(first.Host, state, overall.Token).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Console.WriteLine("[handover] resume failed: " + ex.Message);
                outcome = HandoverOutcome.Lost;
            }
            OnResume?.Invoke(outcome == HandoverOutcome.Switched, from, Snapshot.Link ?? first.Kind);
            if (outcome != HandoverOutcome.Switched)
                End(L10nResumeFailed());
        });
    }

    private static string L10nResumeFailed() =>
        "The link dropped and no other link took over";

    private Queue<(string Host, LinkKind Kind)> BuildResumeAlternates(string lostHost, LinkKind lostKind)
    {
        var addrs = PeerAddresses.Count > 0 ? PeerAddresses.ToList() : new List<string> { lostHost };
        if (!addrs.Contains(lostHost)) addrs.Insert(0, lostHost);
        var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
        var remote = addrs.Select(a => new RemoteAddress(a)).ToList();
        var routes = RoutePlanner.Plan(local, remote).ToList();
        // Prefer same address on another NIC, then other addresses; skip exact current host+kind duplicate first try order.
        var q = new Queue<(string Host, LinkKind Kind)>();
        foreach (var r in routes.Where(r => r.Address != lostHost || r.Kind != lostKind))
            q.Enqueue((r.Address, r.Kind));
        foreach (var a in addrs.Where(a => a != lostHost))
        {
            if (q.Any(x => x.Host == a)) continue;
            var kind = a.StartsWith("169.254.", StringComparison.Ordinal) ? LinkKind.ethernet : LinkKind.wifi;
            q.Enqueue((a, kind));
        }
        // Last resort: retry the same host (receiver may have rebound).
        if (q.Count == 0) q.Enqueue((lostHost, lostKind == LinkKind.ethernet ? LinkKind.wifi : LinkKind.ethernet));
        return q;
    }

    private async Task<HandoverOutcome> RunHandoverAsync(string host, HandoffState h, CancellationToken ct = default)
    {
        try
        {
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                using var perTry = CancellationTokenSource.CreateLinkedTokenSource(ct);
                perTry.CancelAfter(HandoverTimeout);
                Connection c;
                try
                {
                    c = await Connection.ConnectAsync(host, _port, TimeSpan.FromSeconds(2), perTry.Token).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[handover] connect {host}: {ex.Message}");
                    if (h.Resume && h.Alternates.Count > 0)
                    {
                        var next = h.Alternates.Dequeue();
                        host = next.Host;
                        h.Kind = next.Kind;
                        h.TryingHost = host;
                        h.Nonce = Pairing.Nonce();
                        h.ReceiverNonce = null;
                        h.Proven = false;
                        h.Gbps = null;
                        Console.WriteLine($"[handover] trying next {host} ({h.Kind})");
                        continue;
                    }
                    return FinishHandoff(h.Resume ? HandoverOutcome.Lost : HandoverOutcome.Stayed);
                }

                h.Connection = c;
                h.TryingHost = host;
                c.OnMessage = m => HandoffMessage(m, h);
                c.OnClose = reason =>
                {
                    if (ReferenceEquals(_handoff, h) && !h.Switching)
                        HandoffFailed(reason);
                };
                c.Start();
                c.Send(JsonWire.Message(MessageType.Handover, new HandoverNonce { Nonce = h.Nonce }));

                h.ProbeDone = new TaskCompletionSource<double>(TaskCreationOptions.RunContinuationsAsynchronously);
                using (perTry.Token.Register(() => h.ProbeDone.TrySetCanceled()))
                {
                    try
                    {
                        h.Gbps = await h.ProbeDone.Task.ConfigureAwait(false);
                    }
                    catch
                    {
                        try { c.Dispose(); } catch { /* ignore */ }
                        if (h.Resume && h.Alternates.Count > 0)
                        {
                            var next = h.Alternates.Dequeue();
                            host = next.Host;
                            h.Kind = next.Kind;
                            h.Nonce = Pairing.Nonce();
                            h.ReceiverNonce = null;
                            h.Proven = false;
                            h.Connection = null;
                            continue;
                        }
                        return FinishHandoff(h.Resume ? HandoverOutcome.Lost : HandoverOutcome.Stayed);
                    }
                }

                h.Switching = true;
                h.SwitchEcho = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var old = _conn;

                if (h.Resume || old is null || old.IsClosed)
                {
                    // Old link gone: Switchover on the new connection (Mac resume path).
                    c.Send(new Message(MessageType.Switchover));
                }
                else
                {
                    old.OnClose = reason =>
                    {
                        if (_handoff?.Switching == true) return;
                        ConnectionClosed(reason);
                    };
                    old.Send(new Message(MessageType.Switchover));
                }

                using var switchWait = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                using (switchWait.Token.Register(() => h.SwitchEcho.TrySetCanceled()))
                {
                    try { await h.SwitchEcho.Task.ConfigureAwait(false); }
                    catch (OperationCanceledException)
                    {
                        Console.WriteLine("[handover] switchover unanswered");
                        try { c.Dispose(); } catch { /* ignore */ }
                        if (h.Resume && h.Alternates.Count > 0)
                        {
                            var next = h.Alternates.Dequeue();
                            host = next.Host;
                            h.Kind = next.Kind;
                            h.Switching = false;
                            h.Nonce = Pairing.Nonce();
                            h.ReceiverNonce = null;
                            h.Proven = false;
                            h.Gbps = null;
                            h.Connection = null;
                            continue;
                        }
                        return FinishHandoff(h.Resume ? HandoverOutcome.Lost : HandoverOutcome.Stayed);
                    }
                }

                _conn = c;
                _host = host;
                _linkKind = h.Kind;
                Snapshot.Link = h.Kind;
                Snapshot.MissingLink = null;
                RefreshRouteInterface(host, h.Kind);
                Snapshot.CapacityGbps = h.Gbps;
                if (Snapshot.Config is { } current && Snapshot.Peer is { } welcome)
                {
                    var cfg = PathPolicy.Relink(current, h.Kind, h.Gbps, welcome);
                    Snapshot.Config = cfg;
                    if (cfg.Video is { } v)
                    {
                        Snapshot.VideoBitrate = v.Bitrate;
                        Snapshot.VideoStartBitrate = v.Bitrate;
                    }
                    try { c.Send(JsonWire.Message(MessageType.Reconfigure, cfg)); } catch { /* ignore */ }
                }
                c.OnMessage = m =>
                {
                    try { Handle(m); }
                    catch (Exception ex) { End("handle: " + ex.Message); }
                };
                c.OnClose = ConnectionClosed;

                if (old is not null && !ReferenceEquals(old, c))
                {
                    old.OnMessage = null;
                    old.OnClose = null;
                    try { old.CloseAfterFlush("handed over"); } catch { /* ignore */ }
                }

                try { _cursorConn?.Dispose(); } catch { /* ignore */ }
                _cursorConn = null;
                if (Snapshot.Peer?.ChannelToken is { } tok and not 0)
                    _ = OpenCursorChannelAsync(tok);

                Snapshot.State = "Streaming";
                Publish();
                Console.WriteLine($"[handover] {(h.Resume ? "resumed" : "switched")} to {h.Kind} via {host}, {h.Gbps:F2} Gbps");
                return FinishHandoff(HandoverOutcome.Switched);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("[handover] failed: " + ex.Message);
            try { h.Connection?.Dispose(); } catch { /* ignore */ }
            return FinishHandoff(h.Resume ? HandoverOutcome.Lost : HandoverOutcome.Stayed);
        }
    }

    private void HandoffMessage(Message m, HandoffState h)
    {
        if (!ReferenceEquals(_handoff, h) || h.Connection is not { } c) return;
        switch (m.Type)
        {
            case MessageType.HandoverChallenge:
            {
                var challenge = JsonWire.Decode<HandoverNonce>(m.Payload);
                if (challenge.Nonce.Length != 16)
                {
                    HandoffFailed("bad handover challenge");
                    return;
                }
                h.ReceiverNonce = challenge.Nonce;
                c.Send(JsonWire.Message(MessageType.HandoverProof, new AuthProof
                {
                    Mac = Handover.Proof(h.Secret, Handover.Role.Sender, h.Nonce, challenge.Nonce),
                }));
                return;
            }
            case MessageType.HandoverOK:
            {
                if (h.ReceiverNonce is not { } theirs) { HandoffFailed("handoverOK early"); return; }
                var proof = JsonWire.Decode<AuthProof>(m.Payload);
                var expect = Handover.Proof(h.Secret, Handover.Role.Receiver, h.Nonce, theirs);
                if (!Pairing.Matches(proof.Mac, expect))
                {
                    HandoffFailed("handover proof mismatch");
                    return;
                }
                h.Proven = true;
                _ = Task.Run(() => ProbeHandoff(c, h));
                return;
            }
            case MessageType.ProbeResult:
            {
                if (!h.Proven || h.Gbps is not null) return;
                var result = JsonWire.Decode<ProbeResult>(m.Payload);
                h.ProbeDone?.TrySetResult(result.Gbps);
                return;
            }
            case MessageType.Switchover:
                if (h.Switching) h.SwitchEcho?.TrySetResult();
                return;
            case MessageType.Bye:
            {
                var bye = JsonWire.Decode<Bye>(m.Payload);
                HandoffFailed(bye.Reason.Length > 0 ? bye.Reason : "handover refused");
                return;
            }
        }
    }

    private static void ProbeHandoff(Connection c, HandoffState h)
    {
        var block = new byte[256 << 10];
        Random.Shared.NextBytes(block);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var handed = 0L;
        try
        {
            while (sw.Elapsed < TimeSpan.FromSeconds(0.3) && !c.IsClosed && h.ProbeDone is { Task.IsCompleted: false })
            {
                var queued = c.QueuedBytes;
                var elapsed = Math.Max(0.001, sw.Elapsed.TotalSeconds);
                var acked = Math.Max(0L, handed - queued);
                var target = ProbeQueueBytes(acked, elapsed);
                if (queued < target)
                {
                    var n = (int)Math.Min(block.Length, Math.Max(64 << 10, target / 4));
                    var payload = n == block.Length ? block : block.AsSpan(0, n).ToArray();
                    c.Send(new Message(MessageType.Probe, 0, payload));
                    handed += n;
                }
                else Thread.Sleep(2);
            }
            if (h.ProbeDone is { Task.IsCompleted: false })
                c.Send(new Message(MessageType.Probe, ProbeFlags.End, Array.Empty<byte>()));
            Thread.Sleep(2000);
            if (h.ProbeDone is { Task.IsCompleted: false })
            {
                var elapsed = Math.Max(0.001, sw.Elapsed.TotalSeconds);
                var gbps = handed > 0 ? handed * 8.0 / elapsed / 1e9 : 1.0;
                h.ProbeDone.TrySetResult(gbps);
            }
        }
        catch (Exception ex)
        {
            h.ProbeDone?.TrySetException(ex);
        }
    }

    private void HandoffFailed(string reason)
    {
        Console.WriteLine("[handover] failed: " + reason);
        try { _handoff?.Connection?.Dispose(); } catch { /* ignore */ }
        var h = _handoff;
        if (h is { Resume: true, Alternates.Count: > 0 })
        {
            // Connect loop in RunHandoverAsync handles alternates on connect failure;
            // mid-handshake failure: signal probe cancel so the loop can advance.
            h.ProbeDone?.TrySetCanceled();
            h.SwitchEcho?.TrySetCanceled();
            return;
        }
        FinishHandoff(h?.Resume == true ? HandoverOutcome.Lost : HandoverOutcome.Stayed);
    }

    private HandoverOutcome FinishHandoff(HandoverOutcome outcome)
    {
        var h = _handoff;
        _handoff = null;
        h?.Done.TrySetResult(outcome);
        return outcome;
    }

    /// <summary>Mac <c>checkRoute</c>: cable/Wi-Fi NIC gone → resume before TCP idle timeout.</summary>
    private void StartRouteWatch()
    {
        StopRouteWatch();
        _inactiveChecks = 0;
        _routeWatch = new Timer(_ => CheckRoute(), null, 500, 500);
    }

    private void StopRouteWatch()
    {
        try { _routeWatch?.Dispose(); } catch { /* ignore */ }
        _routeWatch = null;
        _inactiveChecks = 0;
    }

    private void CheckRoute()
    {
        try
        {
            if (!CanResume || _linkKind is LinkKind.loopback) { _inactiveChecks = 0; return; }
            var up = RoutePlanner.CurrentInterfaces().Any(i => i.Kind == _linkKind);
            if (up) { _inactiveChecks = 0; return; }
            _inactiveChecks++;
            // Mac: 1 s cable (2×0.5), 2 s Wi-Fi (4×0.5).
            var need = _linkKind == LinkKind.wifi ? 4 : 2;
            if (_inactiveChecks < need) return;
            _inactiveChecks = 0;
            var name = FasterLinkPolicy.LinkName(_linkKind);
            LinkLost($"{name} disconnected");
        }
        catch { /* ignore timer races */ }
    }

    /// <summary>Resolve the local NIC name for the active receiver address (Mac snapshot.interface).</summary>
    private void RefreshRouteInterface(string host, LinkKind kind)
    {
        try
        {
            var local = RoutePlanner.CurrentInterfaces().Where(i => i.Kind != LinkKind.loopback).ToList();
            var remote = (PeerAddresses.Count > 0 ? PeerAddresses : new[] { host })
                .Select(a => new RemoteAddress(a)).ToList();
            var routes = RoutePlanner.Plan(local, remote);
            var match = routes.FirstOrDefault(r => r.Address == host);
            if (string.IsNullOrEmpty(match.Interface))
                match = routes.FirstOrDefault(r => r.Kind == kind);
            _routeInterface = string.IsNullOrEmpty(match.Interface) ? null : match.Interface;
            Snapshot.Interface = _routeInterface ?? kind.ToString();
        }
        catch
        {
            Snapshot.Interface = kind.ToString();
        }
    }
}
