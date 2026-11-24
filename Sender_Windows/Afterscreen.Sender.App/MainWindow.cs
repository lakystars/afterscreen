using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Session;

namespace Afterscreen.Sender.App;

/// <summary>
/// The Mac Sender's popover (idle list, streaming page, settings page) as a window above the notification area.
/// Features Windows does not have yet are drawn the same way but disabled (see <see cref="Ui.Unavailable{T}"/>).
/// </summary>
public sealed class MainWindow : Window
{
    private readonly AppModel _m;
    private readonly Ui _ui = new();
    private readonly StackPanel _body = new() { Margin = new Thickness(12, 12, 12, 8) };
    private readonly StackPanel _footer = new() { Margin = new Thickness(12, 0, 12, 12) };
    private readonly ScrollViewer _scroll;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private string _key = "";
    private string _code = "";
    private bool _showOthers;
    private int _wrongSeen;

    public MainWindow(AppModel model)
    {
        _m = model;
        Width = 400;
        ResizeMode = ResizeMode.CanMinimize;
        ShowInTaskbar = true;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Background = Theme.Bg;
        Foreground = Theme.Fg;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        UseLayoutRounding = true;
        Title = "Afterscreen";

        _scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _body,
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(_scroll);
        Grid.SetRow(_footer, 1);
        root.Children.Add(_footer);
        Content = root;

        _m.Changed += () => Dispatcher.BeginInvoke(new Action(Refresh));
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Render();
    }

    /// <summary>True once the app is really quitting (Quit button, tray menu, Windows sign-out); until then the X button only hides.</summary>
    public static bool Quitting { get; set; }

    private bool _placed;

    /// <summary>The X button sends the app back to the notification area instead of ending it.</summary>
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!Quitting)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    /// <summary>Tray click: show (or bring forward) the window, or hide it when it is already in front.</summary>
    public void ToggleFromTray()
    {
        if (IsVisible && WindowState != WindowState.Minimized && IsActive) { Hide(); return; }
        ShowWindow();
    }

    public void ShowWindow()
    {
        Render();
        if (!IsVisible)
        {
            var wa = SystemParameters.WorkArea;
            MaxHeight = Math.Max(320, wa.Height - 16);
            if (!_placed)
            {
                // First time: above the notification area, where the tray icon is
                UpdateLayout();
                Left = wa.Right - Width - 12;
                Top = Math.Max(wa.Top + 8, wa.Bottom - 700);
                _placed = true;
            }
            Show();
        }
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    // ---- refresh ---------------------------------------------------------------------------------------------------

    private string StructureKey()
    {
        var s = _m.Snapshot;
        var phase = !_m.IsActive ? "idle" : s is null ? "connecting" : s.Phase.ToString();
        // While pairing, ignore discovery-list churn so CodeBoxes are not rebuilt (focus/typing die).
        var receivers = phase == nameof(SessionPhase.Pairing)
            ? ""
            : string.Join(",", _m.VisibleReceivers.Select(r => r.Address + r.Name + r.Found));
        return string.Join("|", _m.ShowsSettings, phase, s?.PairingName, _m.IsActive, _m.Active?.Address,
            receivers, _m.Settings.ShowConnection,
            _m.Settings.ShowPicture, _m.Settings.ShowResources, _m.Settings.ShowHardware, _m.Settings.DisplayRole,
            _m.Settings.Language, _showOthers,
            phase == nameof(SessionPhase.Pairing) ? "" : _m.LastMessage,
            s?.Config is not null, s?.WrongCodes ?? 0,
            string.Join(",", _m.Pairs.Select(p => p.Id)), OptionsKey(s?.ReceiverOptions), _m.Settings.Deband, _m.FlashBlocks,
            _m.Sound, s?.SoundOnHeadphones, _m.BrightnessFollows, _m.AvailableUpdate?.Version, _m.Settings.ChecksUpdates,
            _m.IsTesting, _m.TestReport?.Done, _m.TestReport?.Running?.Width, _m.TestReport?.RunningTypical, _m.TestReport?.Finished);
    }

    private static string OptionsKey(ReceiverOptions? o) => o is null ? "-"
        : $"{o.Editable}{o.Hud}{o.Presentation}{o.Screen}{o.MatchPanelMode}{o.Effect}{o.OnDisconnect}{o.LaunchAtLogin}{o.Screens.Count}{o.MissingScreen}";

    private void Refresh()
    {
        var key = StructureKey();
        if (key != _key)
        {
            if (_m.Snapshot is { } s && s.WrongCodes != _wrongSeen)
            {
                _wrongSeen = s.WrongCodes;
                _code = "";
            }
            if (IsVisible) Render();
            else _key = "";           // rebuilt the next time it opens
        }
        else if (IsVisible)
        {
            _ui.RunUpdaters();
        }
    }

    private void Render()
    {
        _key = StructureKey();
        _ui.ClearUpdaters();
        _body.Children.Clear();
        _footer.Children.Clear();
        var inSession = _m.IsActive;
        if (_m.ShowsSettings) _body.Children.Add(SettingsPage());
        else if (inSession && _m.IsTesting) _body.Children.Add(TestPage());
        else if (inSession) _body.Children.Add(StreamingPage());
        else _body.Children.Add(IdlePage());
        if (!_m.ShowsSettings) BuildFooter(inSession);
        _scroll.ScrollToTop();
    }

    private void BuildFooter(bool inSession)
    {
        _footer.Children.Add(new Border { Height = 1, Background = Theme.Line, Margin = new Thickness(0, 0, 0, 10) });
        if (_m.AvailableUpdate is { } update)
            _footer.Children.Add(UpdateRow(update));
        if (inSession && _m.LastMessage is { } msg)
            _footer.Children.Add(Note(msg));
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (inSession)
            row.Children.Add(AlignLeft(Ui.Btn(_m.IsTesting ? L10n.T("Stop", "중지") : L10n.T("Disconnect", "연결 끊기"),
                () => _m.Disconnect(powerReceiver: !_m.IsTesting))));
        else if (_m.LastMessage is { } m)
            row.Children.Add(AlignLeft(Note(m)));
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(Ui.Btn(L10n.T("Settings", "설정"), () => { _m.ShowsSettings = true; Render(); }));
        var quit = Ui.Btn(L10n.T("Quit", "종료"), () =>
        {
            _m.Disconnect(powerReceiver: true);
            Quitting = true;
            Application.Current.Shutdown();
        });
        quit.Margin = new Thickness(6, 0, 0, 0);
        right.Children.Add(quit);
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        _footer.Children.Add(row);
    }

    private UIElement UpdateRow(AvailableUpdate update)
    {
        var receiver = _m.ReceiverName;
        var mac = _m.MachineName;
        var text = update.Windows && update.Receiver
            ? L10n.T($"Version {update.Version} is out for {mac} and {receiver}", $"버전 {update.Version}이 {mac}과 {receiver}용으로 나왔습니다")
            : update.Receiver
                ? L10n.T($"Version {update.Version} is out for {receiver}", $"버전 {update.Version}이 {receiver}용으로 나왔습니다")
                : L10n.T($"Version {update.Version} is out", $"버전 {update.Version}이 나왔습니다");
        var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(Note(text));
        var dl = Ui.Btn(L10n.T("Download", "다운로드"), () =>
        {
            try { Process.Start(new ProcessStartInfo(update.Page.AbsoluteUri) { UseShellExecute = true }); }
            catch { /* ignore */ }
        });
        Grid.SetColumn(dl, 1);
        row.Children.Add(dl);
        return row;
    }

    private static FrameworkElement AlignLeft(FrameworkElement e)
    {
        e.HorizontalAlignment = HorizontalAlignment.Left;
        e.VerticalAlignment = VerticalAlignment.Center;
        return e;
    }

    private static TextBlock Note(string text) =>
        Ui.Text(text, 11, Theme.Sub, wrap: true);

    private static StackPanel Stack(double gap, IEnumerable<UIElement> items)
    {
        var p = new StackPanel();
        foreach (var i in items)
        {
            if (p.Children.Count > 0 && i is FrameworkElement f) f.Margin = new Thickness(f.Margin.Left, gap, f.Margin.Right, f.Margin.Bottom);
            p.Children.Add(i);
        }
        return p;
    }

    // ---- idle ------------------------------------------------------------------------------------------------------

    private UIElement IdlePage()
    {
        var items = new List<UIElement> { Ui.Text("Afterscreen", 15, weight: FontWeights.SemiBold) };
        if (_m.TestReport is { } lastReport) items.Add(QualityCard(lastReport, testing: false));
        var rows = new List<UIElement>();
        var receivers = _m.VisibleReceivers;
        if (receivers.Count == 0)
            rows.Add(Ui.Text(L10n.T(
                "Looking for Afterscreen Receiver… Start it on the Mac to use as a screen, then connect an Ethernet cable, or join the same network.",
                "Afterscreen Receiver를 찾는 중… 화면으로 쓸 Mac에서 실행한 뒤 이더넷 케이블을 연결하거나 같은 네트워크에 연결하세요."),
                12, Theme.Sub, wrap: true));
        var mine = receivers.Where(_m.IsPaired).ToList();
        var others = receivers.Where(r => !_m.IsPaired(r)).ToList();
        foreach (var r in mine) rows.Add(ReceiverRow(r));
        if (mine.Count == 0) foreach (var r in others) rows.Add(ReceiverRow(r));
        else if (others.Count > 0)
        {
            rows.Add(Ui.SectionTitle(L10n.T($"Other receivers ({others.Count})", $"다른 수신기 ({others.Count})"),
                () => _showOthers, () => { _showOthers = !_showOthers; Render(); }));
            if (_showOthers) foreach (var r in others) rows.Add(ReceiverRow(r));
        }
        rows.Add(AddReceiverRow());
        items.Add(Ui.Card(L10n.T("Receivers", "수신기"), rows));
        return Stack(10, items);
    }

    private UIElement AddReceiverRow()
    {
        var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var box = new TextBox
        {
            FontSize = 12,
            Padding = new Thickness(6, 3, 6, 3),
            Background = Theme.Field,
            Foreground = Theme.Fg,
            BorderBrush = Theme.Line,
            CaretBrush = Theme.Fg,
            ToolTip = L10n.T("Receiver address, e.g. 192.168.0.12:50206 (port optional)", "수신기 주소 예: 192.168.0.12:50206 (포트 생략 가능)"),
        };
        var add = Ui.Btn(L10n.T("Add", "추가"), () =>
        {
            if (_m.AddReceiver(box.Text) is null)
                box.BorderBrush = Theme.Red;
            else
            {
                box.Text = "";
            }
        });
        add.Margin = new Thickness(6, 0, 0, 0);
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) add.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); };
        g.Children.Add(box);
        Grid.SetColumn(add, 1);
        g.Children.Add(add);
        return g;
    }

    private UIElement ReceiverRow(ReceiverEntry r)
    {
        var p = new StackPanel { Margin = new Thickness(0, 2, 0, 6) };
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(Ui.Text(string.IsNullOrEmpty(r.Name) ? r.Host : r.Name, 13, weight: FontWeights.Medium));
        if (_m.IsPaired(r))
        {
            var lockMark = Ui.Text("🔒", 10, Theme.Sub);
            lockMark.Margin = new Thickness(4, 0, 0, 0);
            lockMark.ToolTip = L10n.T("Paired: connects over Ethernet and Wi-Fi without a code", "페어링됨: 이더넷·Wi-Fi에서도 코드 없이 연결합니다");
            head.Children.Add(lockMark);
        }
        p.Children.Add(head);
        var sub = string.Join(" · ", new[] { r.Model, r.Panel, r.Address }.Where(s => !string.IsNullOrEmpty(s)));
        p.Children.Add(Ui.Text(sub, 11, Theme.Sub));
        var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var link = LinkPicker(r);
        link.HorizontalAlignment = HorizontalAlignment.Left;
        row.Children.Add(link);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        var remove = Ui.Btn("✕", () => _m.RemoveReceiver(r));
        remove.ToolTip = L10n.T("Remove from the list", "목록에서 삭제");
        buttons.Children.Add(remove);
        var test = Ui.Btn(L10n.T("Test", "테스트"), () => _m.RunQualityTest(r));
        test.ToolTip = L10n.T("Measure the highest resolution and frame rate, then typical use, on this receiver and link",
                              "이 수신기와 링크로 낼 수 있는 최대 해상도와 프레임, 실사용 프레임을 측정합니다");
        test.Margin = new Thickness(6, 0, 0, 0);
        buttons.Children.Add(test);
        var connect = Ui.Btn(L10n.T("Connect", "연결"), () => _m.Connect(r), primary: true);
        connect.Margin = new Thickness(6, 0, 0, 0);
        buttons.Children.Add(connect);
        Grid.SetColumn(buttons, 1);
        row.Children.Add(buttons);
        p.Children.Add(row);
        return p;
    }

    /// <summary>Mac link pin: Automatic + answering kinds (unreachable pinned kept, dimmed).</summary>
    private ComboBox LinkPicker(ReceiverEntry? forReceiver = null)
    {
        var available = _m.AnsweringLinks(forReceiver ?? _m.Active);
        var pinned = RoutePlanner.ParsePreferred(_m.Settings.PreferredLink);
        var choices = LinkMenu.Choices(available, pinned);
        // Fall back to the four pins when discovery has no plan yet (list still empty / Wi-Fi only later).
        if (choices.Count == 0)
        {
            choices = new[]
            {
                new LinkMenu.Choice(LinkKind.thunderbolt, false),
                new LinkMenu.Choice(LinkKind.usb, false),
                new LinkMenu.Choice(LinkKind.ethernet, true),
                new LinkMenu.Choice(LinkKind.wifi, true),
            };
        }

        var labels = new List<string> { L10n.T("Automatic", "자동") };
        var keys = new List<string> { "auto" };
        foreach (var ch in choices)
        {
            var name = LinkNameOf(ch.Kind);
            labels.Add(ch.Reachable ? name : name + L10n.T(" (not reachable now)", " (지금 연결 안 됨)"));
            keys.Add(RoutePlanner.PreferKey(ch.Kind));
        }

        var prefer = _m.Settings.PreferredLink;
        var idx = keys.IndexOf(prefer);
        if (idx < 0) idx = 0;
        var c = Ui.Combo(labels, idx, i =>
        {
            if (i >= 0 && i < keys.Count) _m.SetPreferredLink(keys[i]);
        });
        c.ToolTip = L10n.T(
            "Automatic uses the fastest link that reaches the receiver. Pin a kind when more than one answers.",
            "자동은 수신기에 닿는 가장 빠른 링크를 씁니다. 여러 링크로 응답할 때 종류를 고정합니다.");
        return c;
    }

    // ---- quality test ----------------------------------------------------------------------------------------------

    private UIElement TestPage()
    {
        var items = new List<UIElement> { Ui.Text(L10n.T("Quality test", "품질 테스트"), 15, weight: FontWeights.SemiBold) };
        if (_m.Snapshot is { Phase: SessionPhase.Pairing, PairingName: { } pairing } s)
            items.Add(PairingCard(pairing, s.WrongCodes > 0));
        var receiver = _m.TestReport?.Receiver ?? _m.ReceiverName;
        items.Add(Ui.Text(L10n.T($"{receiver} shows full-motion frames at each size for a few seconds.",
                                 $"{receiver}에 크기별로 몇 초씩 전체가 움직이는 화면이 나옵니다."), 11, Theme.Sub, wrap: true));
        if (_m.TestReport is { } report) items.Add(QualityCard(report, testing: true));
        else items.Add(Ui.Text(PhaseText(_m.Snapshot), 11, Theme.Sub));
        return Stack(10, items);
    }

    /// <summary>Quality test result: verdict, link, one bar per stage, typical use (Mac QualityCard).</summary>
    private UIElement QualityCard(QualityTest.Report report, bool testing)
    {
        var rows = new List<UIElement>();
        if (report.Verdict is { } v)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal };
            line.Children.Add(Ui.Text($"{QualityTest.Label(v.Size)} · {Math.Round(v.Fps)} fps", 22, weight: FontWeights.Bold));
            if (v.Motion is { } m && (m.Width != v.Size.Width || m.Height != v.Size.Height))
            {
                var motion = Ui.Text(L10n.T($"motion {QualityTest.Label(m)}", $"움직임 {QualityTest.Label(m)}"), 13, Theme.Sub, FontWeights.SemiBold);
                motion.Margin = new Thickness(8, 4, 0, 0);
                line.Children.Add(motion);
            }
            rows.Add(line);
        }
        else if (!testing && report.Stages.Count > 0)
            rows.Add(Ui.Text(L10n.T($"Under {Math.Round(QualityTest.SmoothFps(report.FrameRate))} fps at every size",
                                    $"모든 크기에서 {Math.Round(QualityTest.SmoothFps(report.FrameRate))}fps 미만"), 15, weight: FontWeights.SemiBold));
        if (report.Link is { } link)
            rows.Add(Ui.Text($"{LinkNameOf(link)}{(report.Path.Length > 0 ? " · " + report.Path : "")}", 11, Theme.Sub));
        foreach (var st in report.Stages) rows.Add(StageRow(st, QualityTest.Label(st.Size), report.FrameRate));
        if (report.Typical is { } t) rows.Add(StageRow(t, L10n.T("Typical", "실사용"), report.FrameRate));
        if (testing && !report.Finished)
        {
            var g = new Grid { Margin = new Thickness(0, 4, 0, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(1, report.Total), Value = report.Done, Height = 6, VerticalAlignment = VerticalAlignment.Center });
            var what = report.Running is { } run
                ? (report.RunningTypical ? L10n.T("Testing typical use…", "실사용 측정 중…") : L10n.T($"Testing {QualityTest.Label(run)}…", $"{QualityTest.Label(run)} 측정 중…"))
                : L10n.T("Measuring the link…", "링크 측정 중…");
            var label = Ui.Text(what, 11, Theme.Sub);
            label.Margin = new Thickness(8, 0, 0, 0);
            Grid.SetColumn(label, 1);
            g.Children.Add(label);
            rows.Add(g);
        }
        return Ui.Card(L10n.T($"Quality test · {report.Receiver}", $"품질 테스트 · {report.Receiver}"), rows);
    }

    private static UIElement StageRow(QualityTest.Stage stage, string label, double rate)
    {
        var color = stage.Fps >= QualityTest.SmoothFps(rate) ? Theme.Green : stage.Fps >= rate / 2 ? Theme.Orange : Theme.Red;
        var g = new Grid();
        foreach (var w in new[] { 52.0, 92.0, 0.0, 66.0, 56.0, 0.0 })
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = w == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(w) });
        g.ColumnDefinitions.RemoveAt(5);
        void Put(UIElement e, int col) { Grid.SetColumn(e, col); g.Children.Add(e); }
        Put(Ui.Text(label, 11, mono: true), 0);
        Put(Ui.Text($"{stage.Size.Width}×{stage.Size.Height}", 11, Theme.Sub, mono: true), 1);
        var bar = new Grid { Width = 60, Height = 6, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        bar.Children.Add(new Border { Background = Theme.Line, CornerRadius = new CornerRadius(3) });
        bar.Children.Add(new Border { Background = color, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left, Width = 60 * Math.Min(1, stage.Fps / Math.Max(1, rate)) });
        Put(bar, 2);
        var fps = Ui.Text($"{Math.Round(stage.Fps)} fps", 11, mono: true);
        fps.HorizontalAlignment = HorizontalAlignment.Right;
        Put(fps, 3);
        var gb = Ui.Text($"{stage.Gbps:0.0} Gb/s", 11, Theme.Sub, mono: true);
        gb.HorizontalAlignment = HorizontalAlignment.Right;
        Put(gb, 4);
        return g;
    }

    private static string LinkNameOf(LinkKind k) => k switch
    {
        LinkKind.thunderbolt => "Thunderbolt",
        LinkKind.usb => "USB",
        LinkKind.ethernet => "Ethernet",
        LinkKind.wifi => "Wi-Fi",
        LinkKind.loopback => "Loopback",
        _ => "—",
    };

    // ---- streaming -------------------------------------------------------------------------------------------------

    private UIElement StreamingPage()
    {
        var s = _m.Snapshot;
        var receiver = _m.ReceiverName;
        var mac = _m.MachineName;
        var items = new List<UIElement>();

        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Ui.Text(s?.Peer?.MarketingName is { Length: > 0 } mk ? mk : receiver, 15, weight: FontWeights.SemiBold));
        var status = _ui.Live(() => _m.Snapshot is { Phase: SessionPhase.Streaming }
            ? "● " + L10n.T("Streaming", "스트리밍 중")
            : PhaseText(_m.Snapshot), 11, mono: false);
        status.Foreground = s is { Phase: SessionPhase.Streaming } ? Theme.Green : Theme.Sub;
        _ui.OnTick(() => status.Foreground = _m.Snapshot is { Phase: SessionPhase.Streaming } ? Theme.Green : Theme.Sub);
        Grid.SetColumn(status, 1);
        head.Children.Add(status);
        items.Add(head);

        if (s is { Phase: SessionPhase.Pairing, PairingName: { } pairing })
            items.Add(PairingCard(pairing, s.WrongCodes > 0));

        items.Add(SoundCard(receiver, mac));
        if (s is { Phase: SessionPhase.Streaming })
            items.Add(BrightnessCard(receiver, mac));

        items.Add(ConnectionSection(receiver, mac));
        items.Add(PictureCard(receiver, mac));
        items.Add(ResourcesSection(receiver, mac));
        if (s?.Peer is { } peer) items.Add(HardwareSection(peer));
        return Stack(10, items);
    }

    private static string PhaseText(SenderSnapshot? s) => s is null ? L10n.T("Connecting…", "연결 중…") : s.Phase switch
    {
        SessionPhase.Connecting => L10n.T("Connecting…", "연결 중…"),
        SessionPhase.Pairing => s.State.StartsWith("Wrong", StringComparison.Ordinal) ? L10n.T("Wrong code", "코드가 맞지 않음") : L10n.T("Pairing…", "페어링 중…"),
        SessionPhase.Probing => L10n.T("Measuring the link…", "링크 측정 중…"),
        SessionPhase.Streaming => L10n.T("Streaming", "스트리밍 중"),
        _ => s.State,
    };

    private UIElement ConnectionSection(string receiver, string mac)
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.SectionTitle(L10n.T("Connection", "연결"), () => _m.Settings.ShowConnection, () =>
        {
            _m.Settings.ShowConnection = !_m.Settings.ShowConnection;
            _m.Settings.Save();
            Render();
        }));

        var chart = new Grid { Height = 92, Margin = new Thickness(0, 4, 0, 0) };
        var canvas = Ui.SeriesCanvas(() => _m.ThroughputHistory, () => _m.LatencyHistory, _ui);
        chart.Children.Add(canvas);
        var overlay = new Grid { Margin = new Thickness(8) };
        overlay.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        overlay.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var score = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
        var scoreText = _ui.Live(() => _m.Snapshot?.Stats?.CableScore is { } c ? c.ToString() : "—", 26, Theme.Sub, mono: false);
        scoreText.FontWeight = FontWeights.SemiBold;
        scoreText.TextAlignment = TextAlignment.Center;
        _ui.OnTick(() =>
        {
            var c = _m.Snapshot?.Stats?.CableScore;
            scoreText.Foreground = c is null ? Theme.Sub : c >= 80 ? Theme.Green : c >= 50 ? Theme.Orange : Theme.Red;
        });
        score.Children.Add(scoreText);
        var q = Ui.Text(L10n.T("Link quality", "링크 품질"), 10);
        q.HorizontalAlignment = HorizontalAlignment.Center;
        score.Children.Add(q);
        score.ToolTip = L10n.T("100 = clean link with headroom; lower when retransmits, jitter, or the link is too slow for this stream",
            "100은 여유 있는 깨끗한 링크; 재전송·지터·스트림에 비해 느린 링크일수록 낮아집니다");
        overlay.Children.Add(score);
        var values = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        var linkLine = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        linkLine.Children.Add(Ui.Text(LinkName(), 12));
        var picker = LinkPicker();
        picker.Margin = new Thickness(6, 0, 0, 0);
        linkLine.Children.Add(picker);
        values.Children.Add(linkLine);
        values.Children.Add(ValueLine(L10n.T("Throughput", "전송량"), () => Fmt.Rate(_m.Snapshot?.Stats?.ThroughputBitsPerSecond), Theme.Green));
        values.Children.Add(ValueLine(L10n.T("Latency", "지연"), () => Fmt.Ms(_m.Snapshot?.Stats?.LatencyMs), Theme.Blue));
        values.Children.Add(ValueLine(L10n.T("Changed blocks", "바뀐 블록"), () => Fmt.Blocks(_m.Snapshot), Theme.Fg));
        Grid.SetColumn(values, 1);
        overlay.Children.Add(values);
        chart.Children.Add(overlay);
        panel.Children.Add(new Border
        {
            Background = Theme.Card,
            CornerRadius = new CornerRadius(8),
            ClipToBounds = true,
            Margin = new Thickness(0, 4, 0, 0),
            Child = chart,
        });

        // Warnings stay visible while the section is folded (Mac PopoverView).
        var missing = Ui.Text("", 11, Theme.Orange, wrap: true);
        missing.Margin = new Thickness(0, 4, 0, 0);
        void Missing()
        {
            if (_m.Snapshot?.MissingLink is { } mk)
            {
                var name = LinkNameOf(mk);
                missing.Text = L10n.T($"{name} does not reach the receiver; using the fastest link",
                                      $"{name}(으)로는 수신기에 닿지 않아 가장 빠른 링크를 씁니다");
                missing.Visibility = Visibility.Visible;
            }
            else missing.Visibility = Visibility.Collapsed;
        }
        Missing();
        _ui.OnTick(Missing);
        panel.Children.Add(missing);

        var usbTip = Ui.Text("", 11, Theme.Orange, wrap: true);
        usbTip.Margin = new Thickness(0, 4, 0, 0);
        void UsbTip()
        {
            var tip = LinkMetrics.UsbFallbackAdvice(_m.Snapshot?.Link ?? _m.Snapshot?.Config?.LinkKind);
            if (tip is not null)
            {
                usbTip.Text = L10n.T(tip,
                    "Thunderbolt가 아닌 USB로 연결됐습니다. Thunderbolt 케이블이면 양쪽을 뽑았다 다시 꽂고, 계속 USB이면 한쪽을 잠자기하거나 재시동하세요.");
                usbTip.Visibility = Visibility.Visible;
            }
            else usbTip.Visibility = Visibility.Collapsed;
        }
        UsbTip();
        _ui.OnTick(UsbTip);
        panel.Children.Add(usbTip);

        var lowered = Ui.Text("", 11, Theme.Orange, wrap: true);
        lowered.Margin = new Thickness(0, 4, 0, 0);
        void Lowered()
        {
            var sn = _m.Snapshot;
            if (sn is { QualityLowered: true, VideoBitrate: { } now, VideoStartBitrate: { } start })
            {
                lowered.Text = L10n.T($"The network is busy: sending at lower quality (video {now / 1_000_000} of {start / 1_000_000} Mbps)",
                                      $"네트워크가 혼잡해 화질을 낮춰 보내는 중입니다(영상 {now / 1_000_000}/{start / 1_000_000} Mbps)");
                lowered.Visibility = Visibility.Visible;
            }
            else lowered.Visibility = Visibility.Collapsed;
        }
        Lowered();
        _ui.OnTick(Lowered);
        panel.Children.Add(lowered);

        if (_m.Settings.ShowConnection)
            panel.Children.Add(WithTop(Ui.Box(
                _ui.ValueRow(L10n.T("Interface", "인터페이스"),
                    () => _m.Snapshot?.Interface ?? _m.Snapshot?.Stats?.Interface ?? "—",
                    L10n.T("This PC's network interface on that link", "그 링크에 쓰이는 이 PC의 네트워크 인터페이스")),
                _ui.ValueRow(L10n.T("Measured link speed", "링크 실측 속도"), () => _m.Snapshot?.CapacityGbps is { } g ? $"{g:0.00} Gb/s" : "—",
                    L10n.T("Measured once at connect by sending data for 0.3 s; not the cable's rated speed", "연결할 때 한 번, 0.3초 동안 실제로 보내 본 속도입니다. 케이블 규격 속도가 아닙니다")),
                _ui.ValueRow(L10n.T("Jitter", "지연 변동"), () => Fmt.Ms(_m.Snapshot?.Stats?.JitterMs),
                    L10n.T("How much the latency varies", "지연 시간이 흔들리는 정도")),
                _ui.ValueRow(L10n.T("Retransmits", "재전송"), () => _m.Snapshot?.Stats is { } st ? $"{st.RetransmitPercent:0.0}%" : "—",
                    L10n.T("Packets sent again after a loss in the last second; high values point at the cable or Wi-Fi",
                           "최근 1초 동안 손실로 다시 보낸 패킷 비율. 높으면 케이블이나 Wi-Fi 상태를 의심하세요")))));
        return panel;
    }

    private static FrameworkElement WithTop(FrameworkElement e)
    {
        e.Margin = new Thickness(0, 4, 0, 0);
        return e;
    }

    /// <summary>Receiver panel brightness (Mac BrightnessCard): follow PC panel or set the receiver alone.</summary>
    private UIElement BrightnessCard(string receiver, string mac)
    {
        var canFollow = Capture.PanelBrightness.IsAvailable;
        var follow = Ui.SwitchRow(
            L10n.T($"Follow {mac}'s brightness", $"{mac} 밝기 따라가기"),
            canFollow && _m.BrightnessFollows,
            on => { if (canFollow) _m.SetBrightnessFollows(on); },
            L10n.T($"On: {receiver} follows this PC's brightness keys and auto-brightness. Off: set {receiver} on its own. {receiver} keeps its level after disconnect.",
                   $"켜면 {receiver} 밝기가 이 PC의 밝기 키·자동 밝기를 따릅니다. 끄면 {receiver} 밝기를 따로 정합니다. 연결을 끊어도 {receiver} 밝기는 그대로 둡니다"));
        var rows = new List<UIElement>
        {
            canFollow
                ? follow
                : Ui.Unavailable(follow, L10n.T("This PC has no readable panel brightness", "이 PC에서 패널 밝기를 읽을 수 없습니다")),
        };
        if (canFollow && _m.BrightnessFollows)
        {
            rows.Add(_ui.LevelSliderLive(() => mac, () => _m.PcBrightness, _m.SetPcBrightness, "☀", "☀"));
            if (_m.PcBrightness is null)
                rows.Add(Ui.Text(L10n.T($"{mac} panel is off or unreadable; {receiver} keeps its brightness",
                                        $"{mac} 패널을 읽을 수 없어 {receiver} 밝기를 그대로 둡니다"), 11, Theme.Sub, wrap: true));
            else
                rows.Add(_ui.LevelSliderLive(
                    () => L10n.T($"{receiver} brightness offset", $"{receiver} 밝기 보정"),
                    () => _m.BrightnessOffsetForActive(),
                    _m.SetBrightnessOffset, "−", "+",
                    min: Protocol.BrightnessOffset.Min, max: Protocol.BrightnessOffset.Max,
                    detail: Protocol.BrightnessOffset.Label,
                    help: L10n.T($"Keeps {receiver} brighter or dimmer than {mac} while following. At 0% both screens match. Once {receiver} reaches its maximum, it gets no brighter.",
                                 $"따라가는 동안 {receiver}를 {mac}보다 밝거나 어둡게 맞춥니다. 0%면 같습니다. {receiver}가 최대면 더 밝아지지 않습니다.")));
        }
        if (!canFollow || !_m.BrightnessFollows)
            rows.Add(_ui.LevelSliderLive(() => receiver, () => _m.Brightness, _m.SetReceiverBrightness, "☀", "☀"));
        return Ui.Card(L10n.T("Brightness", "밝기"), rows.ToArray());
    }

    /// <summary>Sound: play on the receiver, and this PC's volume (Mac SoundCard). Session only.</summary>
    private UIElement SoundCard(string receiver, string mac)
    {
        var supported = _m.Snapshot?.Peer is { AudioPlayback: true };
        var rows = new List<UIElement>();
        var sw = Ui.SwitchRow(L10n.T($"Play on {receiver}", $"{receiver}에서 재생"), _m.Sound, _m.SetSound,
            L10n.T($"The PC's sound is captured and sent to {receiver}; {receiver} follows the PC's volume and mute. Headphone and Bluetooth outputs keep the sound. About 1.5 Mbps. The PC is muted while playing on {receiver} when loopback still works (Mac-style).",
                   $"PC에서 나는 소리를 {receiver}로 보내 재생하고, {receiver} 음량과 음소거는 PC 설정을 따릅니다. 헤드폰이나 블루투스 출력으로 들을 때는 넘기지 않습니다. 약 1.5Mbps를 씁니다. 루프백이 유지되면 {receiver} 재생 중 PC 스피커는 음소거됩니다(Mac과 같음)."));
        rows.Add(supported ? sw : Ui.Unavailable(sw, L10n.T($"{receiver} cannot play sound", $"{receiver}에서 소리를 재생할 수 없습니다")));
        if (_m.Sound && _m.Snapshot is { SoundOnHeadphones: true })
            rows.Add(Ui.Text(L10n.T("Headphones in use: sound stays on the PC", "헤드폰 사용 중이라 PC에서 소리가 납니다"), 11, Theme.Sub, wrap: true));
        rows.Add(_ui.LevelSliderLive(
            () => _m.Sound && _m.Snapshot is { SoundOnReceiver: true } ? receiver : mac,
            () => Afterscreen.Sender.Capture.SystemAudio.GetLevel() is { } l ? (l.Muted ? 0 : l.Volume) : null,
            v => Afterscreen.Sender.Capture.SystemAudio.SetVolume((float)v), "🔈", "🔊"));
        return Ui.Card(L10n.T("Sound", "소리"), rows);
    }

    private string LinkName()
    {
        var k = _m.Snapshot?.Link ?? _m.Snapshot?.Config?.LinkKind;
        return k switch
        {
            LinkKind.thunderbolt => "Thunderbolt",
            LinkKind.usb => "USB",
            LinkKind.ethernet => "Ethernet",
            LinkKind.wifi => "Wi-Fi",
            LinkKind.loopback => "Loopback",
            _ => "—",
        };
    }

    private StackPanel ValueLine(string name, Func<string> value, Brush color)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 3, 0, 0) };
        p.Children.Add(Ui.Text(name, 10));
        var v = _ui.Live(value, 12, color);
        v.Margin = new Thickness(6, 0, 0, 0);
        p.Children.Add(v);
        return p;
    }

    private UIElement PictureCard(string receiver, string mac)
    {
        var rows = new List<UIElement>
        {
            RoleRow(),
            Ui.Unavailable(Ui.Row(L10n.T("Optimize for", "맞춤 대상"), Ui.Combo(new[] { mac, receiver }, 1),
                L10n.T($"{mac}: keeps its resolution. {receiver}: the desktop takes its shape.", $"{mac}: 해상도를 그대로 둡니다. {receiver}: 데스크톱이 그 비율에 맞춥니다."))),
            _ui.ValueRow(L10n.T("Frames: captured · sent · shown", "프레임: 캡처 · 전송 · 표시"),
                () => _m.Snapshot?.Stats is { } st
                    ? $"{Math.Round(st.CaptureFPS)} · {Math.Round(st.SentFPS)} · {(_m.Snapshot.Receiver is { } r ? Math.Round(r.DisplayedFPS).ToString() : "—")}" : "—",
                L10n.T($"Per second: frames {mac} drew, sent, and {receiver} showed; shown counts redraws too, so it can pass sent",
                       $"초당 프레임: {mac}에서 그린 것, 보낸 것, {receiver}에서 표시한 것. 표시에는 다시 그린 것도 들어가 보낸 것보다 많을 수 있습니다")),
        };
        if (_m.Settings.ShowPicture)
        {
            rows.Add(_ui.ValueRow(L10n.T("Skipped / min", "건너뛴 프레임/분"), () => _m.Snapshot?.Stats?.DroppedPerMinute.ToString() ?? "—",
                L10n.T("Captures skipped while the link or encoder was busy; their changes go out with the next frame",
                       "링크나 인코더가 바빠 건너뛴 캡처 프레임 수입니다. 바뀐 내용은 다음 프레임에 함께 보냅니다")));
            rows.Add(_ui.ValueRow(L10n.T("Transfer resolution", "전송 해상도"),
                () => _m.Snapshot?.Config is { } c ? $"{c.StreamPixels.Width} × {c.StreamPixels.Height}" : "—"));
            rows.Add(_ui.ValueRow(L10n.T("Motion sent as", "움직임 전송"), () => Fmt.Motion(_m.Snapshot), mono: false));
            rows.Add(_ui.ValueRow(L10n.T("Video target bitrate", "영상 목표 비트레이트"),
                () => _m.Snapshot?.Config?.Video is { } v ? $"{(_m.Snapshot.VideoBitrate ?? v.Bitrate) / 1_000_000.0:0.#} Mbps" : "—",
                L10n.T("What the video encoder aims for; lowered while the network is busy, raised again after. Data actually sent is the throughput",
                       "비디오 인코더가 맞추려는 비트레이트입니다. 네트워크가 혼잡하면 낮추고 풀리면 다시 올립니다. 실제로 보낸 양은 전송량을 보세요")));
            rows.Add(Ui.SwitchRow(L10n.T($"Show sent blocks on {receiver}", $"{receiver}에 보낸 블록 표시"), _m.FlashBlocks, v => _m.FlashBlocks = v,
                L10n.T("For checking: changed blocks flash red, blocks sent again sharper yellow, video blue. Off when Afterscreen starts again",
                       "확인용: 바뀐 블록은 빨강, 선명하게 다시 보낸 블록은 노랑, 비디오는 파랑으로 잠깐 칠합니다. Afterscreen을 다시 실행하면 꺼집니다")));
            if (_m.Snapshot?.ReceiverOptions is { Editable: true } ro)
                rows.Add(Ui.SwitchRow(L10n.T($"Show the HUD on {receiver}", $"{receiver}에 HUD 표시"), ro.Hud,
                    v => _m.ChangeReceiver(new ReceiverOptionsChange { Hud = v }),
                    L10n.T("Link and frame figures over the picture. Option+Command+I on the receiver also shows or hides them",
                           "화면 위에 링크와 프레임 정보를 띄웁니다. 수신기에서 Option+Command+I로도 켜고 끕니다")));
            rows.Add(_ui.ValueRow(L10n.T("Tile LZ4 ratio", "타일 LZ4 압축률"),
                () => _m.Snapshot?.Stats is { CompressionRatio: > 0 } st ? $"{st.CompressionRatio:0.0}×" : "1.0×",
                L10n.T("Tile data size before and after LZ4; 1.0× when the link has room and LZ4 is skipped",
                       "타일 데이터에 LZ4를 건 전후 크기 비율입니다. 링크에 여유가 있으면 LZ4를 쓰지 않아 1.0×입니다")));
        }
        rows.Add(Ui.Row(L10n.T("Smoothing", "계단 완화"),
            Ui.Segmented(new[] { L10n.T("Off", "끔"), L10n.T("Weak", "약"), L10n.T("Normal", "보통"), L10n.T("Strong", "강") }, _m.Settings.Deband, _m.SetDeband),
            L10n.T($"Fills 8-bit steps in dark gradients on {receiver}, in tile areas only, not in video. Higher reaches wider and uses more of its GPU",
                   $"어두운 그라데이션의 8비트 계단을 {receiver}에서 부드럽게 메웁니다. 타일로 보낸 영역에만 적용되고 비디오에는 적용되지 않습니다. 강할수록 넓게 메우고 {receiver} GPU를 더 씁니다")));
        if (_m.Settings.ShowPicture)
            rows.Add(_ui.ValueRow(L10n.T("Frame processing", "프레임 처리 시간"),
                () => _m.Snapshot?.Stats is { } st ? $"{st.EncodeMs:0.0} ms" : "—",
                L10n.T("Average per frame in the last second, from processing start until queued to send, video encoding included",
                       "최근 1초 평균입니다. 프레임 처리를 시작해 송신 대기열에 넣기까지 걸린 시간이며 비디오 인코딩도 들어갑니다")));
        return Ui.Card(L10n.T("Picture", "화면"), rows, () => _m.Settings.ShowPicture, () =>
        {
            _m.Settings.ShowPicture = !_m.Settings.ShowPicture;
            _m.Settings.Save();
            Render();
        });
    }

    private UIElement RoleRow() => Ui.Row(L10n.T("Use as", "사용 방식"),
        Ui.Segmented(new[] { L10n.T("Extend", "확장"), L10n.T("Mirror", "복제") }, _m.Settings.DisplayRole == "extend" ? 0 : 1, i =>
            _m.SetDisplayRole(i == 0 ? "extend" : "mirror")),
        L10n.T("Extend: the receiver shows the second (virtual) monitor. Mirror: it shows the main display.",
               "확장: 수신기에 보조(가상) 모니터가 나옵니다. 복제: 주 디스플레이를 그대로 보여 줍니다."));

    private UIElement ResourcesSection(string receiver, string mac)
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.SectionTitle(L10n.T("Resources · CPU · RAM · GPU", "자원 사용 · CPU · 메모리 · GPU"),
            () => _m.Settings.ShowResources, () =>
            {
                _m.Settings.ShowResources = !_m.Settings.ShowResources;
                _m.Settings.Save();
                Render();
            }));
        if (_m.Settings.ShowResources)
        {
            panel.Children.Add(WithTop(Ui.Box(
                _ui.ValueRow(mac, () => _m.Snapshot?.Stats is { } st
                    ? $"{st.CpuPercent:0}% · {st.MemoryBytes / (1024 * 1024)} MB · GPU {st.GpuPercent:0}%" : "—",
                    L10n.T("This app only. CPU: share of the whole processor. GPU: this process's 3D engines (Windows GPU Engine counters).",
                           "이 앱만 셉니다. CPU는 전체 프로세서 기준입니다. GPU는 이 프로세스의 3D 엔진(Windows GPU Engine 카운터)입니다.")),
                _ui.ValueRow(receiver, () => _m.Snapshot?.Receiver is { } r
                    ? $"{r.CpuPercent:0}% · {r.MemoryBytes / (1024 * 1024)} MB · GPU {r.GpuPercent:0}%"
                    : L10n.T("waiting for stats", "통계 기다리는 중"),
                    L10n.T("This app only. CPU: one core is 100%. GPU: drawing the screen; video decoding not included",
                           "이 앱만 셉니다. CPU는 코어 하나가 100%입니다. GPU는 화면을 그리는 시간이며 비디오 디코딩은 빠집니다")),
                _ui.ValueRow(L10n.T($"{receiver}: upload · decompress", $"{receiver}: 업로드 · 압축 해제"),
                    () => _m.Snapshot?.Receiver is { } r ? $"{r.UploadMs:0.0} · {r.DecompressMs:0.0} ms" : "—",
                    L10n.T($"Latest tile frame on {receiver}: preparing the upload · LZ4 decompression. Video decoding not included",
                           $"{receiver}에서 마지막 타일 프레임을 처리한 시간: 업로드 준비 · LZ4 해제. 비디오 디코딩은 빠집니다")))));
        }
        return panel;
    }

    private UIElement HardwareSection(Welcome p)
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.SectionTitle(L10n.T($"{_m.ReceiverName} hardware", $"{_m.ReceiverName} 하드웨어"),
            () => _m.Settings.ShowHardware, () =>
            {
                _m.Settings.ShowHardware = !_m.Settings.ShowHardware;
                _m.Settings.Save();
                Render();
            }));
        if (_m.Settings.ShowHardware)
        {
            string decode = string.Join(", ", new[] { p.HevcMain10Decode ? "HEVC Main10" : null, p.HevcDecode ? "HEVC" : null, p.H264Decode ? "H.264" : null }.Where(x => x is not null));
            panel.Children.Add(WithTop(Ui.Box(
                Ui.Row(L10n.T("Model", "모델"), Ui.Text(p.MarketingName)),
                Ui.Row(L10n.T("Model identifier", "모델 식별자"), Ui.Text(p.ModelID, mono: true)),
                Ui.Row(L10n.T("Panel", "패널"), Ui.Text($"{p.PanelPixels.Width} × {p.PanelPixels.Height}", mono: true)),
                Ui.Row("GPU", Ui.Text(string.Join(", ", p.GpuNames))),
                Ui.Row("macOS", Ui.Text(p.OsVersion, mono: true)),
                Ui.Row(L10n.T("Hardware video decode", "하드웨어 영상 디코딩"), Ui.Text(decode.Length == 0 ? "—" : decode)))));
        }
        return panel;
    }

    /// <summary>The connected receiver's own settings, as it allows (Mac ReceiverOptionsCard). Who may connect stays on the receiver.</summary>
    private UIElement ReceiverOptionsCard(ReceiverOptions o, string receiver)
    {
        var again = L10n.T("Applies by reconnecting at once", "연결을 다시 맺으며 바로 적용됩니다");
        var screens = new List<string> { L10n.T("Automatic", "자동") };
        var keys = new List<string> { "" };
        foreach (var sc in o.Screens) { screens.Add($"{sc.Name} · {sc.Pixels.Width}×{sc.Pixels.Height}"); keys.Add(sc.Key); }
        if (o.MissingScreen is { } missing && o.Screen is { } mk && !keys.Contains(mk)) { screens.Add(L10n.T($"{missing} (not connected)", $"{missing} (연결 안 됨)")); keys.Add(mk); }
        var screenIndex = o.Screen is null ? 0 : Math.Max(0, keys.IndexOf(o.Screen));
        var presentations = new[] { ReceiverPresentation.space, ReceiverPresentation.cover };
        var effects = new[] { ReceiverEffect.tiles, ReceiverEffect.none };
        var disconnects = new[] { ReceiverOnDisconnect.showDesktop, ReceiverOnDisconnect.sleepDisplay };
        return Ui.Card(L10n.T($"{receiver} settings", $"{receiver} 설정"), new UIElement[]
        {
            Ui.Row(L10n.T("Show the stream", "스트림 표시 방식"),
                Ui.Combo(new[] { L10n.T("A desktop of its own", "별도 데스크톱"), L10n.T("Cover the whole screen", "화면 전체 덮기") }, Array.IndexOf(presentations, o.Presentation),
                    i => _m.ChangeReceiver(new ReceiverOptionsChange { Presentation = presentations[i] })), again),
            Ui.Row(L10n.T("Show on", "표시할 화면"),
                Ui.Combo(screens, screenIndex, i => _m.ChangeReceiver(new ReceiverOptionsChange { Screen = keys[i] })),
                L10n.T($"Automatic: {receiver}'s own panel first. {again}", $"자동: {receiver} 자체 패널을 먼저 씁니다. {again}")),
            Ui.SwitchRow(L10n.T("Switch to the panel's 1:1 resolution", "패널 1:1 해상도로 전환"), o.MatchPanelMode,
                v => _m.ChangeReceiver(new ReceiverOptionsChange { MatchPanelMode = v }),
                L10n.T($"While streaming, a scaled resolution on {receiver} switches to the panel's own, so the stream is not resampled twice. {again}",
                       $"스트리밍하는 동안 {receiver}의 스케일된 해상도를 패널 본래 해상도로 바꿔 스트림이 두 번 리샘플링되지 않게 합니다. {again}")),
            Ui.Row(L10n.T("Connection effect", "연결 효과"),
                Ui.Combo(new[] { L10n.T("Tile wave", "타일 웨이브"), L10n.T("None", "없음") }, Array.IndexOf(effects, o.Effect),
                    i => _m.ChangeReceiver(new ReceiverOptionsChange { Effect = effects[i] })),
                L10n.T("Applies from the next connection", "다음 연결부터 적용됩니다")),
            Ui.Row(L10n.T("Display with no sender", "송신기가 없을 때 화면"),
                Ui.Combo(new[] { L10n.T("Show its desktop", "데스크톱 보기"), L10n.T("Turn the display off", "화면 끄기") }, Array.IndexOf(disconnects, o.OnDisconnect),
                    i => _m.ChangeReceiver(new ReceiverOptionsChange { OnDisconnect = disconnects[i] })),
                L10n.T($"After a disconnect. A stop on {receiver} always shows its desktop", $"연결이 끊긴 뒤의 화면입니다. {receiver}에서 중지하면 항상 데스크톱이 보입니다")),
            Ui.SwitchRow(L10n.T("Open at login", "로그인 시 열기"), o.LaunchAtLogin, v => _m.ChangeReceiver(new ReceiverOptionsChange { LaunchAtLogin = v })),
            Ui.Text(L10n.T($"Connections it accepts, pairings and permission to shut down are set on {receiver}.",
                           $"받을 연결, 페어링, 시스템 종료 허용은 {receiver}에서 설정합니다."), 11, Theme.Sub, wrap: true),
        });
    }

    // ---- pairing ---------------------------------------------------------------------------------------------------

    private UIElement PairingCard(string receiver, bool wrong)
    {
        var rows = new List<UIElement>
        {
            Ui.Text(L10n.T("Type the 6-digit code shown on its screen.", "화면에 뜬 6자리 코드를 입력하세요."), 11, Theme.Sub, wrap: true),
        };
        var boxes = new CodeBoxes(_code, wrong, code => _code = code, () => Submit());
        rows.Add(boxes);
        if (wrong && _code.Length == 0)
            rows.Add(Ui.Text(L10n.T("Wrong code; type it again", "코드가 맞지 않습니다. 다시 입력하세요"), 11, Theme.Red));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
        buttons.Children.Add(Ui.Btn(L10n.T("Cancel", "취소"), () => _m.Disconnect()));
        var pair = Ui.Btn(L10n.T("Pair", "페어링"), () => Submit(), primary: true);
        pair.Margin = new Thickness(6, 0, 0, 0);
        buttons.Children.Add(pair);
        rows.Add(buttons);
        return Ui.Card(L10n.T($"Pair with {receiver}", $"{receiver} 페어링"), rows);

        void Submit()
        {
            if (_code.Length != 6) return;
            var c = _code;
            _code = "";
            _m.SubmitPairingCode(c);
        }
    }

    // ---- settings --------------------------------------------------------------------------------------------------

    private UIElement SettingsPage()
    {
        var mac = _m.MachineName;
        var receiver = _m.IsActive ? _m.ReceiverName : L10n.T("the receiver", "수신기");
        var items = new List<UIElement>();

        var head = new Grid();
        var back = Ui.LinkBtn("‹ " + L10n.T("Back", "뒤로"), () => { _m.ShowsSettings = false; Render(); });
        back.HorizontalAlignment = HorizontalAlignment.Left;
        head.Children.Add(back);
        var title = Ui.Text(L10n.T("Settings", "설정"), 15, weight: FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        head.Children.Add(title);
        items.Add(head);

        // Display
        items.Add(Ui.Card(L10n.T("Display", "디스플레이"), new UIElement[]
        {
            RoleRow(),
            Ui.Unavailable(Ui.Row(L10n.T("Optimize for", "맞춤 대상"), Ui.Combo(new[] { mac, receiver }, 1))),
            Ui.Unavailable(Ui.Row(L10n.T("Size", "크기"), Ui.Combo(new[] { L10n.T("Default", "기본"), L10n.T("Larger text", "큰 글자"), L10n.T("More space", "더 넓게"), L10n.T("Most space", "가장 넓게") }, 0),
                L10n.T("Sets the receiver's desktop size; Windows uses its own display settings", "수신 화면 크기입니다. Windows에서는 디스플레이 설정을 따릅니다"))),
            Ui.Row(L10n.T("Transfer resolution", "전송 해상도"),
                Ui.Combo(new[] { L10n.T("Automatic", "자동"), L10n.T("Panel resolution", "패널 해상도"), L10n.T("Four fifths", "4/5 해상도") },
                    _m.Settings.StreamResolution switch { "panel" => 1, "reduced" => 2, _ => 0 },
                    i => _m.SetStreamResolution(i switch { 1 => "panel", 2 => "reduced", _ => "auto" })),
                L10n.T("Automatic reduces when the link is slow for the panel. Four fifths sends 64% of the pixels; the receiver scales up.",
                       "자동은 패널에 비해 링크가 느리면 줄입니다. 4/5는 픽셀의 64%만 보내고 수신기가 키웁니다.")),
            Ui.Unavailable(Ui.SwitchRow(L10n.T("120 fps (experimental)", "120fps (실험)"), false, _ => { })),
            Ui.LinkBtn(L10n.T("Arrange Displays…", "디스플레이 배치…"), () =>
            {
                try { Process.Start(new ProcessStartInfo("ms-settings:display") { UseShellExecute = true }); } catch { /* no settings app */ }
            }),
        }));

        // Paired receivers
        var pairRows = new List<UIElement>();
        if (_m.Pairs.Count == 0)
            pairRows.Add(Ui.Text(L10n.T(
                "None yet. Over Ethernet or Wi-Fi a receiver asks once for a code shown on its screen; Thunderbolt and USB cables need none.",
                "아직 없습니다. 이더넷이나 Wi-Fi에서는 수신기가 화면에 띄운 코드를 한 번 묻고, Thunderbolt·USB 케이블은 묻지 않습니다."), 11, Theme.Sub, wrap: true));
        foreach (var (id, name) in _m.Pairs)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(Ui.Text(name));
            var rm = Ui.Btn(L10n.T("Remove", "삭제"), () => { _m.RemovePairing(id); Render(); });
            Grid.SetColumn(rm, 1);
            g.Children.Add(rm);
            pairRows.Add(g);
        }
        items.Add(Ui.Card(L10n.T("Paired receivers", "페어링된 수신기"), pairRows));

        // Connection
        items.Add(Ui.Card(L10n.T("Connection", "연결"), new UIElement[]
        {
            Ui.SwitchRow(L10n.T("Connect automatically", "자동으로 연결"), _m.Settings.AutoConnect, _m.SetAutoConnect,
                L10n.T("Reconnect when the last paired receiver appears again, or a Thunderbolt/USB link that needs no code. Disconnect pauses until it leaves the list.",
                       "마지막으로 쓴 페어링된 수신기가 다시 보이거나, 코드가 필요 없는 Thunderbolt/USB 링크면 자동으로 연결합니다. 연결 해제는 목록에서 사라질 때까지 멈춥니다.")),
            Ui.SwitchRow(L10n.T("Open at login", "로그인 시 열기"), _m.LaunchAtLogin, v => _m.LaunchAtLogin = v),
            Ui.Row(L10n.T("Receiver power after disconnecting", "연결 끊은 뒤 수신기 전원"),
                Ui.Combo(new[]
                {
                    L10n.T("Stays on", "켜 두기"),
                    L10n.T("Sleeps", "잠자기"),
                    L10n.T("Shuts down", "시스템 종료"),
                }, _m.Settings.EndPower switch { "sleep" => 1, "shutDown" => 2, _ => 0 }, i =>
                {
                    _m.SetEndPower(i switch { 1 => "sleep", 2 => "shutDown", _ => "keepOn" });
                }),
                L10n.T($"Applies when you click Disconnect or quit Afterscreen. A restart, log out, sleep or dropped link leaves the receiver on. Shutting down needs Allow… in the receiver's settings; until then the receiver sleeps.",
                       $"연결 끊기나 Afterscreen 종료 때 적용됩니다. 재시동·로그아웃·잠자기·링크 끊김에는 수신기를 켜 둡니다. 시스템 종료는 수신기 설정의 허용이 필요하며, 그 전에는 잠자기로 대신합니다.")),
        }));

        if (_m.IsStreaming && _m.Snapshot?.ReceiverOptions is { Editable: true } options)
            items.Add(ReceiverOptionsCard(options, receiver));

        // Notification area (Mac: menu bar)
        items.Add(Ui.Card(L10n.T("Notification area", "알림 영역"), new UIElement[]
        {
            Ui.SwitchRow(L10n.T("Show frame rate and throughput", "프레임과 전송량 표시"), _m.Settings.MenuBarStats, v =>
            {
                _m.Settings.MenuBarStats = v;
                _m.Settings.Save();
            }, L10n.T("Off: the icon only", "끄면 아이콘만 보입니다")),
        }));
        items.Add(Ui.Card(L10n.T("Updates", "업데이트"), new UIElement[]
        {
            Ui.SwitchRow(L10n.T("Check for new versions", "새 버전 확인"), _m.Settings.ChecksUpdates, _m.SetChecksUpdates),
        }));

        var lang = Ui.Combo(new[] { L10n.T("Automatic", "자동"), "English", "한국어" },
            _m.Settings.Language switch { "en" => 1, "ko" => 2, _ => 0 }, i =>
            {
                _m.Settings.Language = i switch { 1 => "en", 2 => "ko", _ => "auto" };
                L10n.Korean = i switch { 1 => false, 2 => true, _ => System.Globalization.CultureInfo.InstalledUICulture.TwoLetterISOLanguageName == "ko" };
                _m.Settings.Save();
                Render();
            });
        lang.HorizontalAlignment = HorizontalAlignment.Left;
        items.Add(Ui.Card(L10n.T("Language", "언어"), new UIElement[] { lang }));
        return Stack(10, items);
    }
}

/// <summary>Six boxes drawn over one hidden text box, as the Mac pairing card (3 + 3, the way the Receiver shows the code).</summary>
public sealed class CodeBoxes : Grid
{
    // Opacity 0 can refuse keyboard on some hosts; hit-test goes through the digit row onto this field.
    private readonly TextBox _input = new()
    {
        Opacity = 0.01,
        MaxLength = 6,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        Foreground = Brushes.Transparent,
        CaretBrush = Brushes.Transparent,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    private readonly List<Border> _boxes = new();
    private readonly List<TextBlock> _digits = new();
    private readonly bool _wrong;

    public CodeBoxes(string initial, bool wrong, Action<string> changed, Action submit)
    {
        _wrong = wrong;
        Margin = new Thickness(0, 4, 0, 4);
        Focusable = true;
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            IsHitTestVisible = false, // clicks reach _input underneath
        };
        for (var i = 0; i < 6; i++)
        {
            var digit = Ui.Text("", 22, weight: FontWeights.SemiBold);
            digit.HorizontalAlignment = HorizontalAlignment.Center;
            var box = new Border
            {
                Width = 42,
                Height = 42,
                CornerRadius = new CornerRadius(7),
                Background = Theme.Field,
                BorderThickness = new Thickness(1),
                Margin = new Thickness(i == 3 ? 20 : i == 0 ? 0 : 8, 0, 0, 0),
                Child = digit,
            };
            _boxes.Add(box);
            _digits.Add(digit);
            row.Children.Add(box);
        }
        Children.Add(_input);
        Children.Add(row);
        _input.Text = initial;
        _input.PreviewTextInput += (_, e) => e.Handled = e.Text.Length > 0 && !e.Text.All(char.IsAsciiDigit);
        _input.TextChanged += (_, _) =>
        {
            var digits = new string(_input.Text.Where(char.IsAsciiDigit).Take(6).ToArray());
            if (digits != _input.Text) { _input.Text = digits; _input.CaretIndex = digits.Length; }
            changed(digits);
            Draw();
        };
        _input.KeyDown += (_, e) => { if (e.Key == Key.Enter) submit(); };
        GotKeyboardFocus += (_, _) => _input.Focus();
        MouseLeftButtonDown += (_, _) => _input.Focus();
        Loaded += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            _input.Focus();
            _input.CaretIndex = _input.Text.Length;
            Keyboard.Focus(_input);
        }, DispatcherPriority.Input);
        Draw();
    }

    private void Draw()
    {
        var text = _input.Text;
        var next = Math.Min(text.Length, 5);
        for (var i = 0; i < 6; i++)
        {
            _digits[i].Text = i < text.Length ? text[i].ToString() : "";
            _boxes[i].BorderBrush = _wrong && text.Length == 0 ? Theme.Red
                : i == next && IsKeyboardFocusWithin ? Theme.Accent : (i < text.Length ? Theme.Sub : Theme.Line);
            _boxes[i].BorderThickness = new Thickness(i == next ? 2 : 1);
        }
    }
}

/// <summary>Value text shared by the popover rows (Mac <c>StatValue</c>).</summary>
public static class Fmt
{
    public static string Rate(double? bitsPerSecond) => bitsPerSecond switch
    {
        null => "—",
        >= 1e9 => $"{bitsPerSecond / 1e9:0.00} Gb/s",
        _ => $"{bitsPerSecond / 1e6:0} Mb/s",
    };

    public static string Ms(double? ms) => ms is { } v and > 0 ? $"{v:0.#} ms" : "—";

    public static string Blocks(SenderSnapshot? s)
    {
        if (s?.Stats is not { } st || s.Config is not { } c) return "—";
        var total = ((c.StreamPixels.Width + 63) / 64) * ((c.StreamPixels.Height + 63) / 64);
        return total <= 0 ? "—" : $"{Math.Round(st.DirtyPercent / 100 * total)} / {total}";
    }

    public static string Motion(SenderSnapshot? s)
    {
        if (s?.Config is not { } c) return "—";
        if (c.Video is not { } v) return "BC1";
        var codec = v.Codec == VideoCodec.hevc ? "HEVC" : "H.264";
        return $"{codec}{(v.TenBit ? " 10-bit" : "")} {v.Pixels.Width} × {v.Pixels.Height}";
    }
}
