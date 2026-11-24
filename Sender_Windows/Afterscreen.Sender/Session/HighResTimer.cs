using System.Runtime.InteropServices;

namespace Afterscreen.Sender.Session;

/// <summary>
/// Raises the Windows timer resolution (default ~15.6 ms) for the lifetime of the scope.
/// Without it Thread.Sleep(1..4) wakes on 15.6 ms ticks, so a 31 ms frame interval lands on
/// 46.8 ms and a 30 fps stream tops out near 21 fps regardless of encode cost.
/// </summary>
internal sealed class HighResTimer : IDisposable
{
    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod")]
    private static extern uint TimeBeginPeriod(uint ms);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod")]
    private static extern uint TimeEndPeriod(uint ms);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWaitableTimerExW(IntPtr attrs, string? name, uint flags, uint access);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetWaitableTimer(IntPtr timer, ref long dueTime100ns, int period,
        IntPtr completion, IntPtr arg, bool resume);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint ms);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private const uint CreateWaitableTimerHighResolution = 0x2;
    private const uint TimerAllAccess = 0x1F0003;

    private readonly uint _ms;
    private bool _active;
    private IntPtr _waitTimer;

    private HighResTimer(uint ms)
    {
        _ms = ms;
        try { _active = TimeBeginPeriod(ms) == 0; }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            Console.Error.WriteLine($"[timer] timeBeginPeriod unavailable: {ex.Message}");
        }
    }

    public static HighResTimer Begin(uint ms = 1)
    {
        var t = new HighResTimer(ms);
        try
        {
            // timeBeginPeriod is ignored for windowless/hidden processes on Windows 11, so waits
            // go through a high-resolution waitable timer (Win10 1803+), which does not depend on it.
            t._waitTimer = CreateWaitableTimerExW(IntPtr.Zero, null, CreateWaitableTimerHighResolution, TimerAllAccess);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            t._waitTimer = IntPtr.Zero;
        }
        return t;
    }

    /// <summary>Sleep ~<paramref name="ms"/> with sub-tick accuracy; falls back to Thread.Sleep.</summary>
    public void Sleep(int ms)
    {
        if (ms <= 0)
            return;
        if (_waitTimer != IntPtr.Zero)
        {
            var due = -(long)ms * 10_000; // relative, 100 ns units
            if (SetWaitableTimer(_waitTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
            {
                WaitForSingleObject(_waitTimer, (uint)(ms + 50));
                return;
            }
        }
        Thread.Sleep(ms);
    }

    /// <summary>Like <see cref="Sleep(int)"/>, but returns as soon as <paramref name="wake"/> is signalled.</summary>
    public void Sleep(int ms, WaitHandle wake)
    {
        if (ms <= 0)
            return;
        if (_waitTimer != IntPtr.Zero)
        {
            var due = -(long)ms * 10_000;
            if (SetWaitableTimer(_waitTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
            {
                var handles = new[] { wake.SafeWaitHandle.DangerousGetHandle(), _waitTimer };
                WaitForMultipleObjects(2, handles, false, (uint)(ms + 50));
                return;
            }
        }
        wake.WaitOne(ms);
    }

    public void Dispose()
    {
        if (_waitTimer != IntPtr.Zero)
        {
            CloseHandle(_waitTimer);
            _waitTimer = IntPtr.Zero;
        }
        if (!_active) return;
        _active = false;
        TimeEndPeriod(_ms);
    }
}
