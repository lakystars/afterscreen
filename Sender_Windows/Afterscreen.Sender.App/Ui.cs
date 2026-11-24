using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Afterscreen.Sender.App;

/// <summary>Colours follow the Windows light/dark setting (read once at start, as the Mac popover follows the system).</summary>
public static class Theme
{
    public static bool Dark { get; } = DetectDark();
    public static Brush Bg { get; } = Brush(Dark ? "#FF242426" : "#FFF6F6F7");
    public static Brush Fg { get; } = Brush(Dark ? "#FFFFFFFF" : "#FF1D1D1F");
    public static Brush Sub { get; } = Brush(Dark ? "#FF9A9AA0" : "#FF6E6E73");
    public static Brush Card { get; } = Brush(Dark ? "#FF2F2F32" : "#FFE9E9EB");
    public static Brush Line { get; } = Brush(Dark ? "#FF48484C" : "#FFD1D1D6");
    public static Brush Accent { get; } = Brush("#FF0A84FF");
    public static Brush Green { get; } = Brush("#FF30D158");
    public static Brush Blue { get; } = Brush("#FF0A84FF");
    public static Brush Orange { get; } = Brush("#FFFF9F0A");
    public static Brush Red { get; } = Brush("#FFFF453A");
    public static Brush Field { get; } = Brush(Dark ? "#FF1C1C1E" : "#FFFFFFFF");

    public static SolidColorBrush Brush(string hex)
    {
        var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        b.Freeze();
        return b;
    }

    public static Brush WithOpacity(SolidColorBrush b, double o)
    {
        var c = b.Color;
        var r = new SolidColorBrush(Color.FromArgb((byte)(255 * o), c.R, c.G, c.B));
        r.Freeze();
        return r;
    }

    private static bool DetectDark()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }
}

/// <summary>
/// Small widget kit that draws the Mac popover's pieces: cards, label/value rows, switch rows, segmented pickers.
/// Values that change every second are registered as updaters and refreshed without rebuilding the page.
/// </summary>
public sealed class Ui
{
    public const double Font = 12;
    private readonly List<Action> _updaters = new();

    public void ClearUpdaters() => _updaters.Clear();
    public void RunUpdaters()
    {
        foreach (var u in _updaters) u();
    }
    public void OnTick(Action a) => _updaters.Add(a);

    /// <summary>Marks a control as a Mac feature that Windows does not have (yet): shown, dimmed, disabled, with a hint.</summary>
    public static T Unavailable<T>(T c, string? why = null) where T : FrameworkElement
    {
        c.IsEnabled = false;
        c.Opacity = 0.5;
        c.ToolTip = why is null ? L10n.Unavailable : $"{why}\n{L10n.Unavailable}";
        ToolTipService.SetShowOnDisabled(c, true);
        return c;
    }

    public static TextBlock Text(string s, double size = Font, Brush? fg = null, FontWeight? weight = null, bool wrap = false, bool mono = false)
    {
        var t = new TextBlock
        {
            Text = s,
            FontSize = size,
            Foreground = fg ?? Theme.Fg,
            FontWeight = weight ?? FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (mono) t.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        return t;
    }

    public TextBlock Live(Func<string> f, double size = Font, Brush? fg = null, bool mono = true)
    {
        var t = Text(f(), size, fg, mono: mono);
        t.TextAlignment = TextAlignment.Right;
        _updaters.Add(() => { var s = f(); if (t.Text != s) t.Text = s; });
        return t;
    }

    public static Border Box(params UIElement[] rows)
    {
        var p = new StackPanel();
        foreach (var r in rows)
        {
            if (p.Children.Count > 0) ((FrameworkElement)r).Margin = new Thickness(0, 4, 0, 0);
            p.Children.Add(r);
        }
        return new Border
        {
            Background = Theme.Card,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8),
            Child = p,
        };
    }

    /// <summary>Titled group on a tinted box; with <paramref name="expanded"/> the title folds it (chevron at the trailing edge).</summary>
    public static StackPanel Card(string title, IEnumerable<UIElement> rows, Func<bool>? expanded = null, Action? toggle = null)
    {
        var panel = new StackPanel();
        panel.Children.Add(SectionTitle(title, expanded, toggle));
        var list = rows.ToList();
        if (list.Count > 0)
        {
            var box = Box(list.ToArray());
            box.Margin = new Thickness(0, 4, 0, 0);
            panel.Children.Add(box);
        }
        return panel;
    }

    public static UIElement SectionTitle(string title, Func<bool>? expanded = null, Action? toggle = null)
    {
        var t = Text(title, 11, Theme.Sub, FontWeights.SemiBold);
        if (expanded is null || toggle is null) return t;
        var g = new Grid { Background = Brushes.Transparent, Cursor = Cursors.Hand };
        g.Children.Add(t);
        var chevron = new TextBlock
        {
            Text = "›",
            FontSize = 14,
            Foreground = Theme.Sub,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new RotateTransform(expanded() ? 90 : 0),
        };
        g.Children.Add(chevron);
        g.MouseLeftButtonUp += (_, _) => toggle();
        return g;
    }

    /// <summary>Label, then value / control at the trailing edge; <paramref name="help"/> shows on hover.</summary>
    public static Grid Row(string label, UIElement? trailing, string? help = null)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Text(label, Font, Theme.Sub);
        l.Margin = new Thickness(0, 0, 8, 0);
        g.Children.Add(l);
        if (trailing is not null)
        {
            Grid.SetColumn(trailing, 1);
            g.Children.Add(trailing);
        }
        if (help is not null) g.ToolTip = help;
        return g;
    }

    public Grid ValueRow(string label, Func<string> value, string? help = null, bool mono = true)
        => Row(label, Live(value, mono: mono), help);

    public static Grid SwitchRow(string title, bool on, Action<bool> changed, string? help = null)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(Text(title));
        var sw = new ToggleButton { IsChecked = on, Template = SwitchTemplate(), Width = 34, Height = 20, Cursor = Cursors.Hand };
        sw.Checked += (_, _) => changed(true);
        sw.Unchecked += (_, _) => changed(false);
        Grid.SetColumn(sw, 1);
        g.Children.Add(sw);
        if (help is not null) g.ToolTip = help;
        return g;
    }

    private static ControlTemplate SwitchTemplate()
    {
        const string xaml = @"<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='ToggleButton'>
  <Grid>
    <Border x:Name='track' CornerRadius='10' Background='#66808080'/>
    <Ellipse x:Name='knob' Width='16' Height='16' Fill='White' HorizontalAlignment='Left' Margin='2,0,0,0'/>
  </Grid>
  <ControlTemplate.Triggers>
    <Trigger Property='IsChecked' Value='True'>
      <Setter TargetName='track' Property='Background' Value='#FF30D158'/>
      <Setter TargetName='knob' Property='HorizontalAlignment' Value='Right'/>
      <Setter TargetName='knob' Property='Margin' Value='0,0,2,0'/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>";
        return (ControlTemplate)System.Windows.Markup.XamlReader.Parse(xaml);
    }

    public static Button Btn(string text, Action click, bool primary = false)
    {
        var b = new Button
        {
            Content = text,
            FontSize = Font,
            Padding = new Thickness(12, 3, 12, 3),
            MinHeight = 24,
            Cursor = Cursors.Hand,
            Foreground = primary ? Brushes.White : Theme.Fg,
            Background = primary ? Theme.Accent : Theme.Line,
            BorderThickness = new Thickness(0),
            Template = ButtonTemplate(),
        };
        b.Click += (_, _) => click();
        return b;
    }

    private static ControlTemplate ButtonTemplate()
    {
        const string xaml = @"<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>
  <Border x:Name='bd' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' CornerRadius='6' Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}'>
    <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Opacity' Value='0.85'/></Trigger>
    <Trigger Property='IsPressed' Value='True'><Setter TargetName='bd' Property='Opacity' Value='0.7'/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>";
        return (ControlTemplate)System.Windows.Markup.XamlReader.Parse(xaml);
    }

    public static Button LinkBtn(string text, Action click)
    {
        var b = new Button
        {
            Content = text,
            FontSize = Font,
            Foreground = Theme.Accent,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(0),
            Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
                "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><ContentPresenter/></ControlTemplate>"),
        };
        b.Click += (_, _) => click();
        return b;
    }

    /// <summary>Segmented control (Extend | Mirror, Deband levels).</summary>
    public static Border Segmented(IReadOnlyList<string> items, int selected, Action<int> changed)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var buttons = new List<Border>();
        for (var i = 0; i < items.Count; i++)
        {
            var idx = i;
            var label = Text(items[i], 11, i == selected ? Brushes.White : Theme.Fg);
            var seg = new Border
            {
                Padding = new Thickness(10, 3, 10, 3),
                CornerRadius = new CornerRadius(5),
                Background = i == selected ? Theme.Accent : Brushes.Transparent,
                Cursor = Cursors.Hand,
                Child = label,
            };
            seg.MouseLeftButtonUp += (_, _) =>
            {
                if (idx == selected) return;
                selected = idx;
                for (var j = 0; j < buttons.Count; j++)
                {
                    buttons[j].Background = j == selected ? Theme.Accent : Brushes.Transparent;
                    ((TextBlock)buttons[j].Child).Foreground = j == selected ? Brushes.White : Theme.Fg;
                }
                changed(idx);
            };
            buttons.Add(seg);
            row.Children.Add(seg);
        }
        return new Border { Background = Theme.Line, CornerRadius = new CornerRadius(6), Padding = new Thickness(2), Child = row };
    }

    public static ComboBox Combo(IReadOnlyList<string> items, int selected, Action<int>? changed = null, IReadOnlyList<bool>? enabled = null)
    {
        var c = new ComboBox { FontSize = 11, MinWidth = 110, VerticalContentAlignment = VerticalAlignment.Center };
        for (var i = 0; i < items.Count; i++)
        {
            var item = new ComboBoxItem { Content = items[i] };
            if (enabled is not null && !enabled[i]) { item.IsEnabled = false; item.ToolTip = L10n.Unavailable; }
            c.Items.Add(item);
        }
        c.SelectedIndex = selected;
        if (changed is not null) c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) changed(c.SelectedIndex); };
        return c;
    }

    /// <summary>Name over a slider, boxed (brightness / volume). Always shown disabled on Windows.</summary>
    public static Border LevelSlider(string name, double value, string low = "☀", string high = "☀")
    {
        var s = new Slider { Minimum = 0, Maximum = 1, Value = value, VerticalAlignment = VerticalAlignment.Center };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.Children.Add(Text(low, 12, Theme.Sub));
        Grid.SetColumn(s, 1);
        g.Children.Add(s);
        var hi = Text(high, 14, Theme.Sub);
        Grid.SetColumn(hi, 2);
        g.Children.Add(hi);
        var p = new StackPanel();
        p.Children.Add(Text(name));
        g.Margin = new Thickness(0, 6, 0, 0);
        p.Children.Add(g);
        return new Border { Background = Theme.Card, CornerRadius = new CornerRadius(7), Padding = new Thickness(10, 8, 10, 8), Child = p };
    }

    /// <summary>
    /// A name over a slider that follows <paramref name="get"/> every second (not while it is being dragged) and calls
    /// <paramref name="set"/> while the user drags it (Mac LevelSlider with a live level).
    /// </summary>
    public Border LevelSliderLive(Func<string> name, Func<double?> get, Action<double> set, string low, string high,
        double min = 0, double max = 1, Func<double, string>? detail = null, string? help = null)
    {
        var nameText = Text(name());
        var detailText = detail is null ? null : Text(detail(get() ?? min), 11, Theme.Sub);
        var mid = min + (max - min) / 2;
        var slider = new Slider
        {
            Minimum = min, Maximum = max, Value = get() ?? mid,
            VerticalAlignment = VerticalAlignment.Center, IsEnabled = get() is not null,
        };
        var programmatic = false;
        slider.ValueChanged += (_, e) =>
        {
            if (programmatic) return;
            set(e.NewValue);
            if (detailText is not null) detailText.Text = detail!(e.NewValue);
        };
        var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        g.Children.Add(Text(low, 12, Theme.Sub));
        Grid.SetColumn(slider, 1);
        g.Children.Add(slider);
        var hi = Text(high, 14, Theme.Sub);
        Grid.SetColumn(hi, 2);
        g.Children.Add(hi);
        var p = new StackPanel();
        if (detailText is null) p.Children.Add(nameText);
        else
        {
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(nameText);
            Grid.SetColumn(detailText, 1);
            head.Children.Add(detailText);
            p.Children.Add(head);
        }
        p.Children.Add(g);
        _updaters.Add(() =>
        {
            nameText.Text = name();
            var v = get();
            slider.IsEnabled = v is not null;
            if (v is { } level && !slider.IsMouseCaptureWithin && Math.Abs(slider.Value - level) > 0.004)
            {
                programmatic = true;
                slider.Value = level;
                programmatic = false;
                if (detailText is not null) detailText.Text = detail!(level);
            }
        });
        var box = new Border { Background = Theme.Card, CornerRadius = new CornerRadius(7), Padding = new Thickness(10, 8, 10, 8), Child = p };
        if (help is not null) box.ToolTip = help;
        return box;
    }

    /// <summary>Throughput (green, filled) and latency (blue) over the last 60 seconds, each on its own scale.</summary>
    public static Canvas SeriesCanvas(Func<IReadOnlyList<double>> throughput, Func<IReadOnlyList<double>> latency, Ui ui)
    {
        var canvas = new Canvas { ClipToBounds = true, IsHitTestVisible = false };
        var area = new Polygon { Fill = Theme.WithOpacity(Theme.Brush("#FF30D158"), 0.12) };
        var tLine = new Polyline { Stroke = Theme.WithOpacity(Theme.Brush("#FF30D158"), 0.5), StrokeThickness = 1.2 };
        var lLine = new Polyline { Stroke = Theme.WithOpacity(Theme.Brush("#FF0A84FF"), 0.5), StrokeThickness = 1.2 };
        canvas.Children.Add(area);
        canvas.Children.Add(tLine);
        canvas.Children.Add(lLine);
        void Draw()
        {
            var w = canvas.ActualWidth;
            var h = canvas.ActualHeight;
            if (w <= 0 || h <= 0) return;
            Plot(throughput(), 10e6, w, h, tLine, area);
            Plot(latency(), 5, w, h, lLine, null);
        }
        canvas.SizeChanged += (_, _) => Draw();
        ui.OnTick(Draw);
        return canvas;
    }

    private static void Plot(IReadOnlyList<double> all, double floor, double w, double h, Polyline line, Polygon? area)
    {
        const int window = 60;
        var shown = all.Skip(Math.Max(0, all.Count - window)).ToList();
        line.Points.Clear();
        area?.Points.Clear();
        if (shown.Count < 2) return;
        var top = Math.Max(shown.Max(), floor);
        if (top <= 0) return;
        var step = w / (window - 1);
        var start = w - (shown.Count - 1) * step;
        var scale = h * 0.8 / top;
        for (var i = 0; i < shown.Count; i++)
        {
            var p = new Point(start + i * step, h - shown[i] * scale);
            line.Points.Add(p);
            area?.Points.Add(p);
        }
        area?.Points.Add(new Point(w, h));
        area?.Points.Add(new Point(start, h));
    }
}
