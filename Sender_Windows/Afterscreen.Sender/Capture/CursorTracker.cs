using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Capture;

public sealed class CursorTracker : IDisposable
{
    private readonly Rectangle _monitor;
    private readonly CancellationTokenSource _cts = new();
    private Task? _loop;
    private (float x, float y, bool visible)? _lastPos;
    private IntPtr _lastCursorHandle;

    public event Action<float, float, bool>? OnPosition;
    public event Action<byte[], int, int, int, int>? OnImage; // png, w, h, hotX, hotY

    public CursorTracker(Rectangle monitor) => _monitor = monitor;

    public void Start()
    {
        _loop = Task.Run(async () =>
        {
            var unchanged = 0;
            while (!_cts.IsCancellationRequested)
            {
                try { Poll(); }
                catch { /* ignore transient cursor errors */ }
                unchanged = _moved ? 0 : unchanged + 1;
                _moved = false;
                var delay = unchanged >= 60 ? 33 : 8; // ~30 Hz still / ~120 Hz moving
                try { await Task.Delay(delay, _cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        });
    }

    private bool _moved;

    private void Poll()
    {
        if (!GetCursorPos(out var pt))
            return;

        var visible = pt.X >= _monitor.Left && pt.X < _monitor.Right
                      && pt.Y >= _monitor.Top && pt.Y < _monitor.Bottom
                      && _monitor.Width > 0 && _monitor.Height > 0;
        float nx = 0, ny = 0;
        if (_monitor.Width > 0 && _monitor.Height > 0)
        {
            nx = (float)(pt.X - _monitor.Left) / _monitor.Width;
            ny = (float)(pt.Y - _monitor.Top) / _monitor.Height;
        }
        var pos = (nx, ny, visible);
        if (_lastPos is null || _lastPos != pos)
        {
            if (_lastPos is { } old && ((old.visible || visible) && old != pos))
                _moved = true;
            _lastPos = pos;
            OnPosition?.Invoke(nx, ny, visible);
        }

        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref info) || info.hCursor == IntPtr.Zero)
            return;
        if (info.hCursor == _lastCursorHandle)
            return;
        _lastCursorHandle = info.hCursor;

        if (!TryCaptureCursorPng(info.hCursor, out var png, out var w, out var h, out var hotX, out var hotY))
            return;
        OnImage?.Invoke(png, w, h, hotX, hotY);
    }

    private static bool TryCaptureCursorPng(IntPtr hCursor, out byte[] png, out int w, out int h, out int hotX, out int hotY)
    {
        png = Array.Empty<byte>();
        w = h = hotX = hotY = 0;
        if (!GetIconInfo(hCursor, out var ii))
            return false;
        try
        {
            hotX = ii.xHotspot;
            hotY = ii.yHotspot;
            using var icon = Icon.FromHandle(hCursor);
            using var bmp = icon.ToBitmap();
            w = bmp.Width;
            h = bmp.Height;
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            png = ms.ToArray();
            return png.Length > 0;
        }
        finally
        {
            if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
            if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _loop?.Wait(500); } catch { /* ignore */ }
        _cts.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] private static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO piconinfo);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr ho);
}
