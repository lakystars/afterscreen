using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace Afterscreen.Sender.App;

/// <summary>
/// MikeTheTech / Virtual-Display-Driver (MttVDD) control for Afterscreen's virtual monitor only.
/// When <see cref="SessionLifetimeEnabled"/> is true: enable the VDD adapter on session connect,
/// disable it on disconnect (physical extended monitors untouched).
/// <c>SETDISPLAYCOUNT 0</c> is not used — this driver keeps recreating a monitor; adapter PnP only.
/// Flip <see cref="SessionLifetimeEnabled"/> to true when the rest of the feature is ready.
/// </summary>
public static class VirtualDisplayControl
{
    /// <summary>Master switch for VDD session attach/detach. On: enable adapter at Connect, disable at Disconnect.</summary>
    public static readonly bool SessionLifetimeEnabled = true;

    public const string PipeName = "MTTVirtualDisplayPipe";
    public const string AdapterFriendlyName = "Virtual Display Driver";
    public const string MonitorHardwareId = "MTT1337";
    public const int SessionDisplayCount = 1;

    private static int _held;

    /// <summary>Bring up Afterscreen's virtual monitor for a session. No-op when the feature flag is off.</summary>
    public static void ActivateForSession()
    {
        if (!SessionLifetimeEnabled) return;
        try
        {
            if (HasAfterscreenDisplay())
            {
                Interlocked.Exchange(ref _held, 1);
                Console.WriteLine("[vdd] Afterscreen display already present");
                return;
            }

            var id = FindAdapterInstanceId();
            if (id is null)
            {
                Console.WriteLine("[vdd] Virtual Display Driver not installed");
                return;
            }

            if (!IsDeviceStarted(id))
            {
                Console.WriteLine("[vdd] enabling " + id);
                SetDeviceEnabled(id, true);
                WaitForPipe(TimeSpan.FromSeconds(12));
            }

            if (!HasAfterscreenDisplay())
            {
                Console.WriteLine($"[vdd] SETDISPLAYCOUNT {SessionDisplayCount}");
                Send($"SETDISPLAYCOUNT {SessionDisplayCount}", readMs: 45_000);
            }

            WaitForAfterscreenDisplay(TimeSpan.FromSeconds(15));
            Interlocked.Exchange(ref _held, 1);
            Console.WriteLine(HasAfterscreenDisplay()
                ? "[vdd] Afterscreen display active"
                : "[vdd] activate finished but MTT not on desktop");
        }
        catch (Exception ex)
        {
            Console.WriteLine("[vdd] activate failed: " + ex.Message);
        }
    }

    /// <summary>Detach only the Virtual Display Driver. No-op when the feature flag is off. Idempotent.</summary>
    public static void DeactivateForSession()
    {
        if (!SessionLifetimeEnabled) return;
        Interlocked.Exchange(ref _held, 0);
        try
        {
            var id = FindAdapterInstanceId();
            if (id is null)
            {
                Console.WriteLine("[vdd] deactivate: adapter not found");
                return;
            }
            if (!IsDeviceStarted(id) && !HasAfterscreenDisplay())
            {
                Console.WriteLine("[vdd] deactivate: already off");
                return;
            }
            Console.WriteLine("[vdd] disabling " + id);
            SetDeviceEnabled(id, false);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[vdd] deactivate failed: " + ex.Message);
        }
    }

    /// <summary>True when the MTT virtual monitor is attached to the desktop.</summary>
    public static bool HasAfterscreenDisplay()
    {
        try
        {
            var adapter = new DisplayDevice { cb = Marshal.SizeOf<DisplayDevice>() };
            for (uint a = 0; EnumDisplayDevices(null, a, ref adapter, 0); a++)
            {
                var monitor = new DisplayDevice { cb = Marshal.SizeOf<DisplayDevice>() };
                for (uint m = 0; EnumDisplayDevices(adapter.DeviceName, m, ref monitor, 0); m++)
                {
                    if (monitor.DeviceID is null) continue;
                    if (monitor.DeviceID.IndexOf(MonitorHardwareId, StringComparison.OrdinalIgnoreCase) < 0)
                        continue;
                    if ((monitor.StateFlags & DisplayAttachedToDesktop) != 0)
                        return true;
                }
            }
        }
        catch { /* treat as absent */ }
        return false;
    }

    /// <summary>One-shot pipe command. <paramref name="readMs"/> caps how long we wait for the driver to disconnect (reload).</summary>
    public static string Send(string command, int connectMs = 8000, int readMs = 8_000)
    {
        using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
        pipe.Connect(connectMs);
        var bytes = Encoding.Unicode.GetBytes(command);
        pipe.Write(bytes, 0, bytes.Length);
        pipe.Flush();
        // NamedPipeClientStream only honors ReadTimeout with asynchronous Flag on some hosts;
        // use a worker + Join so a wedged driver cannot hang app startup forever.
        var buf = new byte[8192];
        var sb = new StringBuilder();
        Exception? readEx = null;
        var reader = new Thread(() =>
        {
            try
            {
                int n;
                while ((n = pipe.Read(buf, 0, buf.Length)) > 0)
                    sb.Append(Encoding.UTF8.GetString(buf, 0, n));
            }
            catch (Exception ex) { readEx = ex; }
        })
        { IsBackground = true, Name = "vdd-pipe-read" };
        reader.Start();
        if (!reader.Join(readMs))
        {
            // Disposing the pipe unblocks Read; the using below also disposes (safe).
            try { pipe.Dispose(); } catch { /* already closing */ }
            reader.Join(2000);
            throw new TimeoutException($"VDD pipe read timed out after {readMs}ms ({command})");
        }
        if (readEx is IOException or ObjectDisposedException) { /* driver closed / we timed out cleanup */ }
        else if (readEx is not null) throw readEx;
        return sb.ToString();
    }

    private static string? FindAdapterInstanceId()
    {
        try
        {
            using var root = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY");
            if (root is not null)
            {
                foreach (var sub in root.GetSubKeyNames())
                {
                    using var d = root.OpenSubKey(sub);
                    var desc = d?.GetValue("DeviceDesc") as string ?? "";
                    if (desc.IndexOf(AdapterFriendlyName, StringComparison.OrdinalIgnoreCase) >= 0)
                        return @"ROOT\DISPLAY\" + sub;
                }
            }
        }
        catch { /* fall through */ }
        return null;
    }

    private static bool IsDeviceStarted(string instanceId)
    {
        try
        {
            if (CM_Locate_DevNode(out var node, instanceId, 0) != 0) return false;
            if (CM_Get_DevNode_Status(out var status, out _, node, 0) != 0) return false;
            const uint DN_STARTED = 0x8;
            return (status & DN_STARTED) != 0;
        }
        catch { return false; }
    }

    private static void SetDeviceEnabled(string instanceId, bool enable)
    {
        var cr = CM_Locate_DevNode(out var node, instanceId, 0);
        if (cr != 0)
            throw new InvalidOperationException($"CM_Locate_DevNode({instanceId})={cr}");
        cr = enable ? CM_Enable_DevNode(node, 0) : CM_Disable_DevNode(node, 0);
        if (cr != 0)
            throw new InvalidOperationException($"{(enable ? "CM_Enable_DevNode" : "CM_Disable_DevNode")}={cr}");
    }

    private static void WaitForPipe(TimeSpan budget)
    {
        var deadline = DateTime.UtcNow + budget;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (Send("PING", connectMs: 800, readMs: 2000).IndexOf("PONG", StringComparison.OrdinalIgnoreCase) >= 0)
                    return;
            }
            catch { /* not ready */ }
            Thread.Sleep(400);
        }
        Console.WriteLine("[vdd] timed out waiting for pipe");
    }

    private static void WaitForAfterscreenDisplay(TimeSpan budget)
    {
        var deadline = DateTime.UtcNow + budget;
        while (DateTime.UtcNow < deadline)
        {
            if (HasAfterscreenDisplay()) return;
            Thread.Sleep(400);
        }
        Console.WriteLine("[vdd] timed out waiting for MTT on desktop");
    }

    private const int DisplayAttachedToDesktop = 0x1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string? lpDevice, uint iDevNum, ref DisplayDevice lpDisplayDevice, uint dwFlags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("Cfgmgr32.dll", CharSet = CharSet.Unicode, EntryPoint = "CM_Locate_DevNodeW")]
    private static extern int CM_Locate_DevNode(out uint pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("Cfgmgr32.dll")]
    private static extern int CM_Disable_DevNode(uint dnDevInst, int ulFlags);

    [DllImport("Cfgmgr32.dll")]
    private static extern int CM_Enable_DevNode(uint dnDevInst, int ulFlags);

    [DllImport("Cfgmgr32.dll")]
    private static extern int CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, int ulFlags);
}
