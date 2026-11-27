using System.Diagnostics;

namespace Afterscreen.Sender.Session;

/// <summary>
/// Stand-in for Mac <c>GPUTimeMeter</c>.
/// <list type="bullet">
/// <item>Prefer Windows "GPU Engine" PDH utilization for this pid when instances exist (discrete GPUs often do).</item>
/// <item>Else fall back to busy-ms accumulated around GPU encode work (tile/video) vs wall clock —
/// Iris/QSV often has no per-process GPU Engine instances, so PDH alone stays 0.</item>
/// </list>
/// </summary>
internal sealed class GpuMeter : IDisposable
{
    private readonly List<PerformanceCounter> _counters = new();
    private long _resolvedAt;
    private long _windowStart = Environment.TickCount64;
    private double _busyMs;
    private bool _pdhPrimed;

    /// <summary>Record wall time that covered GPU submit/wait (tile encode, video EncodeGpu, etc.).</summary>
    public void AddBusyMs(double ms)
    {
        if (ms > 0) _busyMs += ms;
    }

    /// <summary>Utilization % since the previous call (0…100).</summary>
    public double PercentSinceLastRead()
    {
        var now = Environment.TickCount64;
        var wall = Math.Max(1, now - _windowStart);
        var busyPct = Math.Clamp(_busyMs / wall * 100.0, 0, 100);
        _busyMs = 0;
        _windowStart = now;

        var pdh = TryPdhPercent();
        // Whichever signal is live: PDH when the OS attributes GPU to this pid, else busy-ms.
        return Math.Clamp(pdh > 0.5 ? pdh : busyPct, 0, 100);
    }

    private double TryPdhPercent()
    {
        try
        {
            RefreshPdhIfNeeded();
            if (_counters.Count == 0) return 0;
            double sum = 0;
            foreach (var c in _counters)
            {
                try { sum += c.NextValue(); }
                catch { /* instance vanished */ }
            }
            if (!_pdhPrimed) { _pdhPrimed = true; return 0; }
            return Math.Clamp(sum, 0, 100);
        }
        catch { return 0; }
    }

    private void RefreshPdhIfNeeded()
    {
        var now = Environment.TickCount64;
        var interval = _counters.Count > 0 ? 10_000 : 1_000;
        if (now - _resolvedAt < interval) return;
        DisposeCounters();
        _resolvedAt = now;
        _pdhPrimed = false;
        if (!PerformanceCounterCategory.Exists("GPU Engine")) return;
        var prefix = $"pid_{Environment.ProcessId}_";
        string[] names;
        try { names = new PerformanceCounterCategory("GPU Engine").GetInstanceNames(); }
        catch { return; }
        var threeD = new List<string>();
        var any = new List<string>();
        foreach (var name in names)
        {
            if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            any.Add(name);
            if (name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase)
                || name.Contains("engtype_3d", StringComparison.OrdinalIgnoreCase))
                threeD.Add(name);
        }
        foreach (var name in threeD.Count > 0 ? threeD : any)
        {
            try
            {
                var c = new PerformanceCounter("GPU Engine", "Utilization Percentage", name, readOnly: true);
                _ = c.NextValue();
                _counters.Add(c);
            }
            catch { /* skip */ }
        }
        _pdhPrimed = true;
    }

    private void DisposeCounters()
    {
        foreach (var c in _counters)
            try { c.Dispose(); } catch { /* ignore */ }
        _counters.Clear();
    }

    public void Dispose() => DisposeCounters();
}
