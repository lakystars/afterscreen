using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Afterscreen.Sender.Session;

namespace Afterscreen.Sender.App;

/// <summary>
/// Afterscreen for Windows: starts in the notification area. A tray click opens the window (the Mac Sender's menu),
/// its X button sends it back to the tray, and the tray menu / Quit button ends the app.
/// </summary>
public static class AppMain
{
    [STAThread]
    public static int Main(string[] args)
    {
        using var single = new Mutex(true, @"Local\AfterscreenSenderApp", out var first);
        if (!first)
            return 0;

        var log = Path.Combine(AppSettings.StoreDir, "app-crash.txt");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Crash(log, e.ExceptionObject?.ToString());
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Crash(log, e.Exception.ToString());
            e.Handled = true;
        };

        // VDD session attach is gated by VirtualDisplayControl.SessionLifetimeEnabled (off until the feature is ready).
        if (VirtualDisplayControl.SessionLifetimeEnabled)
            AppDomain.CurrentDomain.ProcessExit += (_, _) => VirtualDisplayControl.DeactivateForSession();

        // Dev: connect-shaped smoke (activate → check MTT → deactivate). No-op / skip when the flag is off.
        if (Array.IndexOf(args, "--vdd-smoke") >= 0)
        {
            if (!VirtualDisplayControl.SessionLifetimeEnabled)
            {
                Console.WriteLine("[vdd-smoke] SKIPPED (SessionLifetimeEnabled=false)");
                return 0;
            }
            VirtualDisplayControl.ActivateForSession();
            var ok = VirtualDisplayControl.HasAfterscreenDisplay();
            Console.WriteLine(ok ? "[vdd-smoke] PASS attached" : "[vdd-smoke] FAIL not attached");
            VirtualDisplayControl.DeactivateForSession();
            return ok ? 0 : 2;
        }

        try
        {
            var model = new AppModel();
            model.StartUpdateChecks();
            var popover = new MainWindow(model);
            using var tray = new TrayIcon(model, popover);
            // Dev switches (used to check the pages without clicking): --connect, --test, --settings, --show
            if (Array.IndexOf(args, "--test") >= 0 || Array.IndexOf(args, "--connect") >= 0)
            {
                // Discovery needs a moment: wait for the first answer (up to 6 s), else the saved entry
                for (var i = 0; i < 30 && model.VisibleReceivers.All(r => !r.Found); i++) System.Threading.Thread.Sleep(200);
                var target = model.VisibleReceivers.FirstOrDefault();
                if (target is not null)
                {
                    if (Array.IndexOf(args, "--test") >= 0) model.RunQualityTest(target); else model.Connect(target);
                    // Dev: turn on "Play on receiver" without clicking the switch.
                    if (Array.IndexOf(args, "--sound") >= 0) model.SetSound(true);
                }
            }
            if (Array.IndexOf(args, "--settings") >= 0) model.ShowsSettings = true;
            // Starts in the notification area; --show opens the window
            app.SessionEnding += (_, _) =>
            {
                // Logoff/shutdown: same as Quit — PowerOff per EndPower, then tear down.
                model.Disconnect(powerReceiver: true);
                MainWindow.Quitting = true;
                if (VirtualDisplayControl.SessionLifetimeEnabled)
                    VirtualDisplayControl.DeactivateForSession();
            };
            if (Array.IndexOf(args, "--show") >= 0)
                tray.ShowWindow();
            app.Run();
        }
        finally
        {
            if (VirtualDisplayControl.SessionLifetimeEnabled)
                VirtualDisplayControl.DeactivateForSession();
        }
        return 0;
    }

    private static void Crash(string path, string? text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, $"{DateTime.Now:o}\n{text}\n\n");
        }
        catch { /* nothing more to do */ }
    }
}

/// <summary>Notification-area icon: the app mark, a green dot while streaming, "fps · throughput" as its tooltip.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly AppModel _model;
    private readonly MainWindow _popover;
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly Icon _idle;
    private readonly Icon _live;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _streaming;

    public TrayIcon(AppModel model, MainWindow popover)
    {
        _model = model;
        _popover = popover;
        _idle = Draw(false);
        _live = Draw(true);
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add(L10n.T("Open", "열기"), null, (_, _) => ShowWindow());
        menu.Items.Add(L10n.T("Quit", "종료"), null, (_, _) =>
        {
            _model.Disconnect(powerReceiver: true);
            MainWindow.Quitting = true;
            System.Windows.Application.Current.Shutdown();
        });
        _icon = new System.Windows.Forms.NotifyIcon { Icon = _idle, Text = "Afterscreen", Visible = true, ContextMenuStrip = menu };
        _icon.MouseUp += (_, e) =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left) _popover.ToggleFromTray();
        };
        _icon.DoubleClick += (_, _) => ShowWindow();
        _timer.Tick += (_, _) => Update();
        _timer.Start();
    }

    public void ShowWindow() => _popover.ShowWindow();

    private void Update()
    {
        var streaming = _model.IsStreaming;
        if (streaming != _streaming)
        {
            _streaming = streaming;
            _icon.Icon = streaming ? _live : _idle;
        }
        var text = "Afterscreen";
        if (streaming)
        {
            var link = FasterLinkPolicy.LinkName(_model.Snapshot?.Link);
            if (_model.Settings.MenuBarStats && _model.Snapshot?.Stats is { } st)
                text = $"Afterscreen · {link} · {Math.Round(st.SentFPS)}fps · {Fmt.Rate(st.ThroughputBitsPerSecond)}";
            else
                text = $"Afterscreen · {link}";
        }
        if (text.Length > 63) text = text[..63];
        if (_icon.Text != text) _icon.Text = text;
    }

    private static Icon Draw(bool live)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var path = new System.Drawing.Drawing2D.GraphicsPath();
            const int r = 7;
            path.AddArc(0, 0, r * 2, r * 2, 180, 90);
            path.AddArc(31 - r * 2, 0, r * 2, r * 2, 270, 90);
            path.AddArc(31 - r * 2, 31 - r * 2, r * 2, r * 2, 0, 90);
            path.AddArc(0, 31 - r * 2, r * 2, r * 2, 90, 90);
            path.CloseFigure();
            using var brush = new System.Drawing.Drawing2D.LinearGradientBrush(new Rectangle(0, 0, 32, 32),
                Color.FromArgb(10, 132, 255), Color.FromArgb(94, 92, 230), 55f);
            g.FillPath(brush, path);
            using var font = new Font("Segoe UI", 18, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("A", font, Brushes.White, new RectangleF(0, 1, 32, 32), sf);
            if (live)
            {
                g.FillEllipse(Brushes.White, 19, 19, 13, 13);
                g.FillEllipse(new SolidBrush(Color.FromArgb(48, 209, 88)), 21, 21, 9, 9);
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _timer.Stop();
        _icon.Visible = false;
        _icon.Dispose();
    }
}
