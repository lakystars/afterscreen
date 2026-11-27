using System.Drawing;
using Afterscreen.Protocol;
using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Encode;
using Xunit;
using Xunit.Abstractions;

namespace Afterscreen.Sender.Tests;

/// <summary>
/// Checks the D3D11 port of the Mac TileEncoder against the pixels it was given: the blocks the GPU writes are
/// decoded here (BC7 mode 6, BC1 with the Mac weights) and compared to the source, and the encoder's policy
/// (BC7 for tiles that change after being still, BC1 / video for moving tiles, BC7 again after settleDelay)
/// is followed frame by frame.
/// </summary>
public class GpuTileEncoderTests
{
    private readonly ITestOutputHelper _out;
    public GpuTileEncoderTests(ITestOutputHelper output) => _out = output;

    /// <summary>The decoded tile must be closer to the new pixels than to the old ones, and reasonably close in absolute terms.</summary>
    private void Quality(string what, double psnrNew, double psnrOld, double min)
    {
        _out.WriteLine($"{what}: PSNR vs new = {psnrNew:0.0} dB, vs old = {psnrOld:0.0} dB");
        Assert.True(psnrNew > psnrOld + 3, $"{what}: decoded tile is not closer to the new pixels ({psnrNew:0.0} vs {psnrOld:0.0})");
        Assert.True(psnrNew >= min, $"{what}: PSNR {psnrNew:0.0} dB < {min} dB");
    }

    private sealed class Rig : IDisposable
    {
        public readonly D3dEncodeDevice Device;
        public readonly GpuFrame Frame;
        public readonly GpuTileEncoder Encoder;
        public readonly byte[] Bgra;
        public readonly int W, H;
        public TileGeometry G => Encoder.Geometry;

        public Rig(int w, int h)
        {
            W = w; H = h;
            Device = D3dEncodeDevice.TryCreate() ?? throw new InvalidOperationException("no D3D11 hardware adapter");
            Frame = new GpuFrame(Device.Device, w, h);
            Encoder = GpuTileEncoder.TryCreate(Device, w, h) ?? throw new InvalidOperationException("tile encoder");
            Bgra = Pattern(w, h, 0);
            Frame.Upload(Device.Context, Bgra);
        }

        public void Set(Rectangle r, int seed)
        {
            var src = Pattern(W, H, seed);
            for (var y = r.Top; y < r.Bottom; y++)
                Buffer.BlockCopy(src, (y * W + r.Left) * 4, Bgra, (y * W + r.Left) * 4, r.Width * 4);
            Frame.Upload(Device.Context, Bgra);
        }

        public void Dispose()
        {
            Encoder.Dispose();
            Frame.Dispose();
            Device.Dispose();
        }
    }

    /// <summary>Gradients, a checker and sharp stripes: smooth areas, hard edges, two-colour blocks.</summary>
    private static byte[] Pattern(int w, int h, int seed)
    {
        var p = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var i = (y * w + x) * 4;
                var checker = (((x + seed * 3) / 8) + ((y + seed) / 8)) % 2 == 0;
                var stripe = ((x + seed) % 23) < 3;
                p[i + 2] = (byte)((x * 255 / Math.Max(1, w - 1) + seed * 17) & 255);
                p[i + 1] = (byte)((y * 255 / Math.Max(1, h - 1) + seed * 29) & 255);
                p[i] = (byte)(checker ? 210 : 35);
                if (stripe) { p[i] = 250; p[i + 1] = 250; p[i + 2] = 250; }
                p[i + 3] = 255;
            }
        }
        return p;
    }

    // ---------------------------------------------------------------- decoders (test side)

    private static uint Bits(byte[] d, int offset, ref int pos, int n)
    {
        uint v = 0;
        for (var i = 0; i < n; i++, pos++)
            v |= (uint)((d[offset + (pos >> 3)] >> (pos & 7)) & 1) << i;
        return v;
    }

    private static readonly int[] Weights = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

    private static void DecodeBc7(byte[] d, int offset, Span<int> rgb /* 16 * 3: r,g,b */)
    {
        var pos = 0;
        Assert.Equal(0x40u, Bits(d, offset, ref pos, 7)); // mode 6
        var q = new int[8];
        for (var i = 0; i < 8; i++) q[i] = (int)Bits(d, offset, ref pos, 7);   // r0 r1 g0 g1 b0 b1 a0 a1
        var p0 = (int)Bits(d, offset, ref pos, 1);
        var p1 = (int)Bits(d, offset, ref pos, 1);
        int[] e0 = [(q[0] << 1) | p0, (q[2] << 1) | p0, (q[4] << 1) | p0];
        int[] e1 = [(q[1] << 1) | p1, (q[3] << 1) | p1, (q[5] << 1) | p1];
        for (var i = 0; i < 16; i++)
        {
            var idx = (int)Bits(d, offset, ref pos, i == 0 ? 3 : 4);
            var w = Weights[idx];
            for (var c = 0; c < 3; c++)
                rgb[i * 3 + c] = ((64 - w) * e0[c] + w * e1[c] + 32) >> 6;
        }
    }

    private static int[] Unpack565(int v)
    {
        int r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
        return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)];
    }

    private static void DecodeBc1(byte[] d, int offset, Span<int> rgb)
    {
        var c0 = d[offset] | (d[offset + 1] << 8);
        var c1 = d[offset + 2] | (d[offset + 3] << 8);
        var bits = (uint)(d[offset + 4] | (d[offset + 5] << 8) | (d[offset + 6] << 16) | (d[offset + 7] << 24));
        var e0 = Unpack565(c0);
        var e1 = Unpack565(c1);
        var pal = new int[4][];
        pal[0] = e0;
        pal[1] = e1;
        pal[2] = new int[3];
        pal[3] = new int[3];
        for (var c = 0; c < 3; c++)
        {
            pal[2][c] = ((64 - 21) * e0[c] + 21 * e1[c] + 32) >> 6;
            pal[3][c] = ((64 - 43) * e0[c] + 43 * e1[c] + 32) >> 6;
        }
        for (var i = 0; i < 16; i++)
        {
            var k = (int)((bits >> (2 * i)) & 3);
            for (var c = 0; c < 3; c++) rgb[i * 3 + c] = pal[k][c];
        }
    }

    /// <summary>Decodes a frame's runs into an RGB picture; returns the picture and which pixels were written.</summary>
    private static (int[] rgb, bool[] set, int bc7Blocks, int bc1Blocks, int videoTiles) Decode(EncodedGpuFrame f, TileGeometry g)
    {
        var rgb = new int[g.Width * g.Height * 3];
        var set = new bool[g.Width * g.Height];
        var o = 0;
        var bc7 = 0; var bc1 = 0; var video = 0;
        var px = new int[48];
        foreach (var run in f.Runs)
        {
            var (bw, bh) = run.Blocks(g);
            if (run.Format == TileFormat.Video) { video += run.Count; continue; }
            for (var by = 0; by < bh; by++)
            {
                for (var bx = 0; bx < bw; bx++)
                {
                    if (run.Format == TileFormat.Bc7) { DecodeBc7(f.Data, o, px); o += 16; bc7++; }
                    else { DecodeBc1(f.Data, o, px); o += 8; bc1++; }
                    var absBx = run.First * g.TileBlocks + bx;
                    var absBy = run.Row * g.TileBlocks + by;
                    for (var i = 0; i < 16; i++)
                    {
                        var x = absBx * 4 + (i & 3);
                        var y = absBy * 4 + (i >> 2);
                        if (x >= g.Width || y >= g.Height) continue;
                        var dst = y * g.Width + x;
                        set[dst] = true;
                        for (var c = 0; c < 3; c++) rgb[dst * 3 + c] = px[i * 3 + c];
                    }
                }
            }
        }
        Assert.Equal(f.DataLength, o);
        return (rgb, set, bc7, bc1, video);
    }

    /// <summary>PSNR (dB) over the pixels the frame wrote, optionally limited to a rectangle.</summary>
    private static double Psnr(int[] rgb, bool[] set, byte[] bgra, int w, Rectangle? area = null)
    {
        double sum = 0;
        var n = 0;
        for (var y = 0; y < bgra.Length / 4 / w; y++)
        {
            for (var x = 0; x < w; x++)
            {
                if (area is { } a && !a.Contains(x, y)) continue;
                var i = y * w + x;
                if (!set[i]) continue;
                var d0 = rgb[i * 3] - bgra[i * 4 + 2];
                var d1 = rgb[i * 3 + 1] - bgra[i * 4 + 1];
                var d2 = rgb[i * 3 + 2] - bgra[i * 4];
                sum += d0 * d0 + d1 * d1 + d2 * d2;
                n += 3;
            }
        }
        Assert.True(n > 0, "no pixel was written");
        var mse = sum / n;
        return mse == 0 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse);
    }

    // ---------------------------------------------------------------- tests

    [Theory]
    [InlineData(256, 192)]   // whole tiles
    [InlineData(200, 150)]   // partial tiles on the right and bottom edges
    public void FirstFrame_IsBc7ForEveryTile_AndDecodesCloseToTheSource(int w, int h)
    {
        using var rig = new Rig(w, h);
        var f = rig.Encoder.Encode(rig.Frame, forceAll: true, dirty: null, now: 1.0);
        Assert.NotNull(f);
        Assert.Equal(rig.G.TileCount, f!.TileCount);
        Assert.All(f.Runs, r => Assert.Equal(TileFormat.Bc7, r.Format));
        var (rgb, set, bc7, bc1, video) = Decode(f, rig.G);
        Assert.Equal(0, bc1 + video);
        Assert.Equal(rig.G.BlocksX * rig.G.BlocksY, bc7);   // every block, edge tiles clipped
        Assert.All(set, s => Assert.True(s));
        Assert.True(Psnr(rgb, set, rig.Bgra, w) > 30, "BC7 picture too far from the source");
        Assert.Equal(0, rig.Encoder.LossyTiles);
    }

    [Fact]
    public void UnchangedFrame_SendsNothing_EvenWithADirtyRectAndTheRefreshSlice()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var again = rig.Encoder.Encode(rig.Frame, false, new[] { new Rectangle(0, 0, 256, 192) }, 2.0);
        Assert.Null(again);
        Assert.Equal(0, rig.Encoder.ChangedTiles);
    }

    [Fact]
    public void TileThatChangesAfterBeingStill_IsSentAsBc7_AndOnlyThatTile()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var area = new Rectangle(70, 70, 10, 10);       // inside tile (1,1) only
        var before = (byte[])rig.Bgra.Clone();
        rig.Set(area, 5);
        var f = rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.0);
        Assert.NotNull(f);
        Assert.Equal(1, f!.TileCount);
        Assert.Equal(TileFormat.Bc7, f.Runs[0].Format);
        Assert.Equal(1, f.Runs[0].Row);
        Assert.Equal(1, f.Runs[0].First);
        var (rgb, set, _, _, _) = Decode(f, rig.G);
        Quality("changed tile (BC7)", Psnr(rgb, set, rig.Bgra, 256, area), Psnr(rgb, set, before, 256, area), 18);
        Assert.Equal(0, rig.Encoder.LossyTiles);
    }

    [Fact]
    public void MovingTile_GoesBc1_ThenSettlesToBc7_AfterSettleDelay()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Motion = TileMotion.Bc1;
        rig.Encoder.Bc7MotionLimit = 0;
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var area = new Rectangle(70, 70, 10, 10);

        rig.Set(area, 5);
        Assert.Equal(TileFormat.Bc7, rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.00)!.Runs[0].Format); // was still

        var seed5 = (byte[])rig.Bgra.Clone();
        rig.Set(area, 6);                                                       // changes again 10 ms later: moving
        var moving = rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.01);
        Assert.NotNull(moving);
        Assert.Equal(TileFormat.Bc1, moving!.Runs[0].Format);
        var (rgb, set, _, bc1, _) = Decode(moving, rig.G);
        Assert.Equal(16 * 16, bc1);
        Quality("moving tile (BC1)", Psnr(rgb, set, rig.Bgra, 256, area), Psnr(rgb, set, seed5, 256, area), 14);
        Assert.Equal(1, rig.Encoder.LossyTiles);

        Assert.Null(rig.Encoder.Refine(rig.Frame, 2.05));                        // only 40 ms still
        Assert.InRange(rig.Encoder.NextRefinement(2.05)!.Value, 0.05, 0.07);

        var settled = rig.Encoder.Refine(rig.Frame, 2.12);                       // > 100 ms still
        Assert.NotNull(settled);
        Assert.Equal(TileFormat.Bc7, settled!.Runs[0].Format);
        var (rgb2, set2, _, _, _) = Decode(settled, rig.G);
        Quality("settled tile (BC7)", Psnr(rgb2, set2, rig.Bgra, 256, area), Psnr(rgb2, set2, seed5, 256, area), 18);
        Assert.Equal(0, rig.Encoder.LossyTiles);
        Assert.Null(rig.Encoder.NextRefinement(2.2));
    }

    [Fact]
    public void MovingTilesWithinTheBc7Budget_StayBc7()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Motion = TileMotion.Bc1;
        rig.Encoder.Bc7MotionLimit = 4;
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var area = new Rectangle(70, 70, 10, 10);
        rig.Set(area, 5);
        rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.00);
        rig.Set(area, 6);
        var moving = rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.01);
        Assert.Equal(TileFormat.Bc7, moving!.Runs[0].Format);       // moving, but 1 tile <= 4
        Assert.Equal(0, rig.Encoder.LossyTiles);
    }

    [Fact]
    public void VideoMode_MovingTileIsAVideoRun_ThenSettlesFromTheLatestPixels()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Motion = TileMotion.Video;
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var area = new Rectangle(70, 70, 10, 10);

        rig.Set(area, 5);
        Assert.Equal(TileFormat.Bc7, rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.00)!.Runs[0].Format);

        rig.Set(area, 6);
        var video = rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.01);
        Assert.NotNull(video);
        Assert.Equal(TileFormat.Video, video!.Runs[0].Format);
        Assert.Equal(0, video.DataLength);                          // video runs carry no data
        Assert.Equal(1, rig.Encoder.LossyTiles);

        var seed6 = (byte[])rig.Bgra.Clone();
        rig.Set(area, 7);                                           // still in motion, already on the video layer
        Assert.Null(rig.Encoder.Encode(rig.Frame, false, new[] { area }, 2.02));   // reference-only update, nothing to send
        Assert.Equal(1, rig.Encoder.ChangedTiles);

        var settled = rig.Encoder.Refine(rig.Frame, 2.20);
        Assert.NotNull(settled);
        Assert.Equal(TileFormat.Bc7, settled!.Runs[0].Format);
        var (rgb, set, _, _, _) = Decode(settled, rig.G);
        Quality("video-mode settle carries the latest pixels", Psnr(rgb, set, rig.Bgra, 256, area), Psnr(rgb, set, seed6, 256, area), 18);
        Assert.Equal(0, rig.Encoder.LossyTiles);
    }

    [Fact]
    public void ForcedFrame_ResendsEverything_AsBc7()
    {
        using var rig = new Rig(256, 192);
        rig.Encoder.Encode(rig.Frame, true, null, 1.0);
        var again = rig.Encoder.Encode(rig.Frame, true, null, 2.0);   // receiver asked for a keyframe
        Assert.Equal(rig.G.TileCount, again!.TileCount);
        Assert.All(again.Runs, r => Assert.Equal(TileFormat.Bc7, r.Format));
    }
}
