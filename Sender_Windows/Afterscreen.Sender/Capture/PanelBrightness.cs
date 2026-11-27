using System.Management;

namespace Afterscreen.Sender.Capture;

/// <summary>
/// Built-in panel brightness via WMI <c>WmiMonitorBrightness</c> (Mac <c>PanelBrightness.builtIn</c>).
/// Level is 0…1 (WMI reports 0…100). Peak nits are unknown on Windows → wire sends level only.
/// </summary>
public static class PanelBrightness
{
    private static int _available = -1; // -1 unknown, 0 no, 1 yes

    public static bool IsAvailable
    {
        get
        {
            if (_available < 0)
                _available = TryRead() is not null ? 1 : 0;
            return _available == 1;
        }
    }

    /// <summary>Current panel slider 0…1, or null when unreadable (desktop / no ACPI backlight).</summary>
    public static double? TryRead()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI",
                "SELECT CurrentBrightness FROM WmiMonitorBrightness WHERE Active=TRUE");
            foreach (ManagementObject o in searcher.Get())
            {
                using (o)
                {
                    var b = Convert.ToDouble(o["CurrentBrightness"]);
                    _available = 1;
                    return Math.Clamp(b / 100.0, 0, 1);
                }
            }
        }
        catch
        {
            _available = 0;
        }
        return null;
    }

    /// <summary>Set the built-in panel slider 0…1. Returns false when unsupported.</summary>
    public static bool TrySet(double level)
    {
        level = Math.Clamp(level, 0, 1);
        var brightness = (byte)Math.Round(level * 100);
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI",
                "SELECT * FROM WmiMonitorBrightnessMethods WHERE Active=TRUE");
            foreach (ManagementObject o in searcher.Get())
            {
                using (o)
                {
                    // WmiSetBrightness(uint Timeout, byte Brightness)
                    o.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, brightness });
                    _available = 1;
                    return true;
                }
            }
        }
        catch { /* unsupported */ }
        return false;
    }
}
