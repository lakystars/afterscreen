using System;
using Microsoft.Win32;

namespace Afterscreen.Sender.App;

/// <summary>
/// Mac <c>SystemSleep</c>: Windows power suspend/resume. Cannot delay sleep the way IOKit
/// <c>IOAllowPowerChange</c> can; best-effort PowerOff then end the session before suspend.
/// </summary>
internal sealed class SystemSleep : IDisposable
{
    public Action? OnSuspend { get; set; }
    public Action? OnResume { get; set; }

    public SystemSleep()
    {
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    public void Dispose()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        switch (e.Mode)
        {
            case PowerModes.Suspend:
                OnSuspend?.Invoke();
                break;
            case PowerModes.Resume:
                OnResume?.Invoke();
                break;
        }
    }
}
