using System.Drawing;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// Reference frame + changed-tile detection shared by the tile encoders.
///
/// The encoder OWNS its reference pixels (copied per changed tile) instead of aliasing the
/// capture buffer. Aliasing broke when the frame gate replaced an unsent capture: the capture
/// double-buffer swapped back onto the buffer the encoder still held, so the next frame was
/// diffed against itself and real changes were dropped until a periodic keyframe.
///
/// Capture dirty rects (Mac: SCStreamFrameInfo.dirtyRects) limit which tiles are compared.
/// Tiles that changed but were not committed (frame skipped before encode) are carried into
/// the next compare so nothing is lost.
/// </summary>
internal sealed class TileRefTracker
{
    private byte[]? _ref;
    private bool[]? _changed;        // result of the last Compute, not yet committed
    private bool[]? _carry;          // changed-but-uncommitted tiles, re-checked next time
    private TileGeometry _geometry;
    private int _width;
    private int _height;
    private int _sinceAudit;

    /// <summary>Frames between full compares that ignore dirty rects (safety net).</summary>
    public int AuditInterval { get; set; } = 90;

    public bool HasPending => _changed is not null;

    /// <summary>Changed-tile mask from the last Compute (null once committed).</summary>
    public bool[]? Changed => _changed;

    /// <summary>
    /// Changed-tile mask for <paramref name="cur"/>. <paramref name="dirty"/> = capture-reported
    /// changed regions in frame pixels; null means unknown (compare every tile).
    /// </summary>
    public bool[] Compute(byte[] cur, int width, int height, TileGeometry g,
        IReadOnlyList<Rectangle>? dirty, out bool forceAll)
    {
        var n = g.TileCount;
        _geometry = g;
        _width = width;
        _height = height;
        var changed = new bool[n];

        forceAll = _ref is null || _ref.Length != cur.Length;
        if (forceAll)
        {
            Array.Fill(changed, true);
            _changed = changed;
            _carry = null;
            return changed;
        }

        var audit = _sinceAudit >= AuditInterval;
        if (audit)
            _sinceAudit = 0;

        var cand = new bool[n];
        if (dirty is null || audit)
            Array.Fill(cand, true);
        else
            MarkTilesUnder(dirty, g, width, height, cand);
        if (_carry is { } carry && carry.Length == n)
            for (var i = 0; i < n; i++)
                if (carry[i]) cand[i] = true;

        var reference = _ref!;
        for (var ty = 0; ty < g.TilesY; ty++)
        {
            for (var tx = 0; tx < g.TilesX; tx++)
            {
                var t = ty * g.TilesX + tx;
                if (cand[t] && TileChanged(cur, reference, width, height, g, tx, ty))
                    changed[t] = true;
            }
        }
        _changed = changed;
        _carry = changed;
        return changed;
    }

    /// <summary>Marks for the last Compute: changed tiles get <paramref name="dirtyMark"/>.</summary>
    public static byte[] ToMarks(bool[] changed, byte dirtyMark)
    {
        var marks = new byte[changed.Length];
        for (var i = 0; i < changed.Length; i++)
            if (changed[i]) marks[i] = dirtyMark;
        return marks;
    }

    /// <summary>Reference := current for every tile the last Compute reported changed.</summary>
    public void Commit(byte[] cur)
    {
        if (_ref is null || _ref.Length != cur.Length || _changed is null)
        {
            // No usable diff (first frame / NotePresented without Probe): full copy.
            if (_ref is null || _ref.Length != cur.Length)
                _ref = new byte[cur.Length];
            Buffer.BlockCopy(cur, 0, _ref, 0, cur.Length);
            _sinceAudit = 0;
        }
        else
        {
            var g = _geometry;
            var rowBytes = _width * 4;
            for (var ty = 0; ty < g.TilesY; ty++)
            {
                for (var tx = 0; tx < g.TilesX; tx++)
                {
                    if (!_changed[ty * g.TilesX + tx]) continue;
                    var x0 = tx * g.TilePixels;
                    var x1 = Math.Min(x0 + g.TilePixels, _width);
                    var y0 = ty * g.TilePixels;
                    var y1 = Math.Min(y0 + g.TilePixels, _height);
                    var len = (x1 - x0) * 4;
                    for (var y = y0; y < y1; y++)
                        Buffer.BlockCopy(cur, y * rowBytes + x0 * 4, _ref, y * rowBytes + x0 * 4, len);
                }
            }
            _sinceAudit++;
        }
        _changed = null;
        _carry = null;
    }

    public void Reset()
    {
        _ref = null;
        _changed = null;
        _carry = null;
        _sinceAudit = 0;
    }

    private static void MarkTilesUnder(IReadOnlyList<Rectangle> rects, TileGeometry g, int width, int height, bool[] cand)
    {
        var tp = g.TilePixels;
        foreach (var r0 in rects)
        {
            var r = Rectangle.Intersect(r0, new Rectangle(0, 0, width, height));
            if (r.Width <= 0 || r.Height <= 0) continue;
            var tx0 = r.Left / tp;
            var tx1 = Math.Min((r.Right - 1) / tp, g.TilesX - 1);
            var ty0 = r.Top / tp;
            var ty1 = Math.Min((r.Bottom - 1) / tp, g.TilesY - 1);
            for (var ty = ty0; ty <= ty1; ty++)
                for (var tx = tx0; tx <= tx1; tx++)
                    cand[ty * g.TilesX + tx] = true;
        }
    }

    private static bool TileChanged(byte[] cur, byte[] prev, int width, int height, TileGeometry g, int tx, int ty)
    {
        var x0 = tx * g.TilePixels;
        var y0 = ty * g.TilePixels;
        var x1 = Math.Min(x0 + g.TilePixels, width);
        var y1 = Math.Min(y0 + g.TilePixels, height);
        // Stride sample first — text edits usually change many pixels in the tile.
        for (var y = y0; y < y1; y += 4)
        {
            var row = y * width;
            for (var x = x0; x < x1; x += 4)
            {
                var i = (row + x) * 4;
                if (cur[i] != prev[i] || cur[i + 1] != prev[i + 1] || cur[i + 2] != prev[i + 2])
                    return true;
            }
        }
        // Full compare for thin strokes the sample might miss.
        // RGB only: capture alpha is not meaningful and must not flag tiles.
        for (var y = y0; y < y1; y++)
        {
            var row = y * width;
            for (var x = x0; x < x1; x++)
            {
                var i = (row + x) * 4;
                if (cur[i] != prev[i] || cur[i + 1] != prev[i + 1] || cur[i + 2] != prev[i + 2])
                    return true;
            }
        }
        return false;
    }
}
