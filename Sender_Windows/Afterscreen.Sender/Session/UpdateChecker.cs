using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>A newer release, and which side it updates (Mac <c>AvailableUpdate</c>).</summary>
public sealed record AvailableUpdate(string Version, Uri Page, bool Windows, bool Receiver);

/// <summary>
/// GitHub's latest release, every 6 hours (Mac <c>UpdateChecker</c>). No server of ours.
/// </summary>
public sealed class UpdateChecker : IDisposable
{
    public const string Repository = "lakystars/afterscreen";

    private static readonly HttpClient Http = CreateClient();
    private readonly object _gate = new();
    private Timer? _timer;
    private CancellationTokenSource? _checkCts;
    private Timer? _retry;
    private Action<string>? _onTag;

    public Action<string>? OnTag
    {
        get { lock (_gate) return _onTag; }
        set { lock (_gate) _onTag = value; }
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_timer is not null) return;
            _timer = new Timer(_ => _ = CheckAsync(), null, 0, 6 * 3600 * 1000);
        }
    }

    public void Stop()
    {
        Timer? t, r;
        CancellationTokenSource? cts;
        lock (_gate)
        {
            t = _timer; _timer = null;
            r = _retry; _retry = null;
            cts = _checkCts; _checkCts = null;
        }
        t?.Dispose();
        r?.Dispose();
        try { cts?.Cancel(); } catch { /* ignore */ }
        cts?.Dispose();
    }

    public void Dispose() => Stop();

    private async Task CheckAsync()
    {
        CancellationTokenSource cts;
        lock (_gate)
        {
            if (_timer is null) return; // stopped
            _checkCts?.Cancel();
            _checkCts?.Dispose();
            cts = _checkCts = new CancellationTokenSource();
        }
        var token = cts.Token;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://api.github.com/repos/{Repository}/releases/latest");
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            req.Headers.UserAgent.ParseAdd($"Afterscreen/{AppVersion.Current ?? "dev"}");
            using var res = await Http.SendAsync(req, token).ConfigureAwait(false);
            var ok = (int)res.StatusCode == 200;
            string? tag = null;
            if (ok)
            {
                var json = await res.Content.ReadAsStringAsync(token).ConfigureAwait(false);
                tag = TagFrom(json);
            }
            lock (_gate)
            {
                if (_timer is null) return;
                if (tag is not null)
                {
                    _onTag?.Invoke(tag);
                    return;
                }
                if (ok || _retry is not null) return;
                // Failures retry every 30 min
                _retry = new Timer(_ =>
                {
                    lock (_gate) { _retry?.Dispose(); _retry = null; }
                    _ = CheckAsync();
                }, null, 1800_000, Timeout.Infinite);
            }
        }
        catch (OperationCanceledException) { /* stopped or replaced */ }
        catch
        {
            lock (_gate)
            {
                if (_timer is null || _retry is not null) return;
                _retry = new Timer(_ =>
                {
                    lock (_gate) { _retry?.Dispose(); _retry = null; }
                    _ = CheckAsync();
                }, null, 1800_000, Timeout.Infinite);
            }
        }
    }

    /// <summary><c>tag_name</c> of a published release shaped like a version.</summary>
    public static string? TagFrom(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("draft", out var d) && d.ValueKind == JsonValueKind.True) return null;
            if (root.TryGetProperty("prerelease", out var p) && p.ValueKind == JsonValueKind.True) return null;
            if (!root.TryGetProperty("tag_name", out var tagEl)) return null;
            var tag = tagEl.GetString();
            if (tag is null || AppVersion.Parts(tag) is null) return null;
            return tag;
        }
        catch { return null; }
    }

    public static Uri? PageFor(string tag) =>
        Uri.TryCreate($"https://github.com/{Repository}/releases/tag/{tag}", UriKind.Absolute, out var u) ? u : null;

    /// <summary>
    /// <paramref name="installed"/> null: unknown (dev). <paramref name="receiver"/> null: none connected;
    /// use "1.0.0" for a peer without a version (Mac).
    /// </summary>
    public static AvailableUpdate? Update(string tag, string? installed, string? receiver)
    {
        var page = PageFor(tag);
        if (page is null) return null;
        var win = installed is not null && AppVersion.IsNewer(tag, installed);
        var peer = receiver is not null && AppVersion.IsNewer(tag, receiver);
        if (!win && !peer) return null;
        var version = tag.StartsWith('v') || tag.StartsWith('V') ? tag[1..] : tag;
        return new AvailableUpdate(version, page, win, peer);
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        c.DefaultRequestHeaders.CacheControl = new CacheControlHeaderValue { NoCache = true };
        return c;
    }
}
