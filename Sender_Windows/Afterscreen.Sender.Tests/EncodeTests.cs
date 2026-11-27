using Afterscreen.Protocol;
using Afterscreen.Sender.Encode;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class EncodeTests
{
    [Fact]
    public void AnnexBToAvcc_SplitsSpsPpsAndSlice()
    {
        // startcode + SPS(7) + startcode + PPS(8) + startcode + slice(1)
        byte[] annex =
        [
            0,0,0,1, 0x67, 0x42, 0x00, 0x0A,
            0,0,0,1, 0x68, 0xCE, 0x06, 0xE2,
            0,0,0,1, 0x65, 0x88, 0x84, 0x00, 0x01
        ];
        var avcc = MfH264Encoder.AnnexBToAvcc(annex, out var sets);
        Assert.Equal(2, sets.Length);
        Assert.Equal(0x67, sets[0][0]);
        Assert.Equal(0x68, sets[1][0]);
        Assert.True(avcc.Length >= 4);
        Assert.Equal(5, (avcc[0] << 24) | (avcc[1] << 16) | (avcc[2] << 8) | avcc[3]);
        Assert.Equal(0x65, avcc[4]);
    }

    [Fact]
    public void AnnexBToHvcc_SplitsVpsSpsPpsAndDetectsIdr()
    {
        // VPS(32) SPS(33) PPS(34) AUD(35, dropped) SEI(39, dropped) IDR_W_RADL(19) slice
        byte[] annex =
        [
            0,0,0,1, 0x40, 0x01, 0x0C,
            0,0,0,1, 0x42, 0x01, 0x01,
            0,0,0,1, 0x44, 0x01, 0xC1,
            0,0,0,1, 0x46, 0x01, 0x50,
            0,0,0,1, 0x4E, 0x01, 0x05,
            0,0,0,1, 0x26, 0x01, 0xAF, 0x08
        ];
        var hvcc = MfH264Encoder.AnnexBToHvcc(annex, out var sets, out var idr);
        Assert.Equal(3, sets.Length);
        Assert.Equal(32, (sets[0][0] >> 1) & 0x3F);
        Assert.Equal(33, (sets[1][0] >> 1) & 0x3F);
        Assert.Equal(34, (sets[2][0] >> 1) & 0x3F);
        Assert.True(idr);
        Assert.Equal(4, (hvcc[0] << 24) | (hvcc[1] << 16) | (hvcc[2] << 8) | hvcc[3]);
        Assert.Equal(19, (hvcc[4] >> 1) & 0x3F);
        Assert.Equal(4 + 4, hvcc.Length); // only the IDR slice survives
    }

    [Fact]
    public void AnnexBToHvcc_TrailingPicture_IsNotIdr()
    {
        byte[] annex = [0,0,0,1, 0x02, 0x01, 0xD0, 0x10]; // TRAIL_R (1)
        MfH264Encoder.AnnexBToHvcc(annex, out var sets, out var idr);
        Assert.Empty(sets);
        Assert.False(idr);
    }

    [Fact]
    public void BgraToNv12_FlatBlue_HasExpectedLumaRange()
    {
        const int w = 16, h = 16;
        var bgra = new byte[w * h * 4];
        for (var i = 0; i < bgra.Length; i += 4) { bgra[i] = 200; bgra[i+1] = 40; bgra[i+2] = 20; bgra[i+3] = 255; }
        var nv12 = new byte[w * h * 3 / 2];
        MfH264Encoder.BgraToNv12(bgra, w, h, nv12);
        Assert.InRange(nv12[0], 16, 235);
        Assert.InRange(nv12[w * h], 16, 240);
    }

    [Fact]
    public void BgraToP010_Bt709VideoRange_BlackWhiteAndGray()
    {
        const int w = 4, h = 4;
        byte[] Make(byte v) { var f = new byte[w * h * 4]; for (var i = 0; i < f.Length; i += 4) { f[i] = v; f[i + 1] = v; f[i + 2] = v; f[i + 3] = 255; } return f; }
        ushort Word(byte[] p, int i) => (ushort)(p[i * 2] | (p[i * 2 + 1] << 8));

        var buf = new byte[w * h * 3];
        MfH264Encoder.BgraToP010(Make(0), w, h, buf);
        Assert.Equal(64 << 6, Word(buf, 0));                  // black: Y10 = 64, sample = 10 bits in the high bits
        Assert.Equal(512 << 6, Word(buf, w * h));             // neutral chroma

        MfH264Encoder.BgraToP010(Make(255), w, h, buf);
        Assert.Equal(940 << 6, Word(buf, 0));                 // white: Y10 = 940
        Assert.Equal(512 << 6, Word(buf, w * h));
        Assert.Equal(512 << 6, Word(buf, w * h + 1));

        MfH264Encoder.BgraToP010(Make(128), w, h, buf);
        Assert.InRange(Word(buf, 0) >> 6, 500, 504);          // mid gray ~ 64 + 876 * 128/255
        Assert.Equal(w * h * 3, buf.Length);                  // 3 bytes per pixel
    }

    [Fact]
    public void BgraToNv12_UsesBt709_NotBt601()
    {
        const int w = 4, h = 4;
        var red = new byte[w * h * 4];
        for (var i = 0; i < red.Length; i += 4) { red[i + 2] = 255; red[i + 3] = 255; }
        var nv12 = new byte[w * h * 3 / 2];
        MfH264Encoder.BgraToNv12(red, w, h, nv12);
        // BT.709 pure red luma = 16 + 219 * 0.2126 ~ 63 (BT.601 would give ~82).
        Assert.InRange(nv12[0], 61, 65);
    }

    [Fact]
    public void GpuAdapters_ListsIrisOrHardware()
    {
        var list = GpuAdapters.List();
        Assert.NotEmpty(list);
        var prefer = GpuAdapters.Prefer();
        Assert.NotNull(prefer);
        Assert.True(prefer!.IsHardware || list.Any(a => a.IsHardware));
    }

    [Fact]
    public void D3dEncodeDevice_CreatesOnPreferredAdapter()
    {
        var d3d = D3dEncodeDevice.TryCreate();
        Assert.NotNull(d3d);
        Assert.False(string.IsNullOrWhiteSpace(d3d!.Adapter.Description));
        d3d.Dispose();
    }

    [Fact]
    public void TileDirty_ProbeThenEncode_UnchangedIsQuiet()
    {
        const int w = 128, h = 128;
        var bgra = new byte[w * h * 4];
        Array.Fill(bgra, (byte)40);
        using var enc = new CpuTileEncoder { KeyframeInterval = 1000 };
        var key = enc.Encode(bgra, w, h, 0);
        Assert.NotNull(key);
        Assert.True(key!.Keyframe);
        var probe = enc.Probe(bgra, w, h);
        Assert.Equal(0, probe.DirtyTiles);
        Assert.Null(enc.Encode(bgra, w, h, 1));
    }

    // The capture buffer is reused in place. The encoder must keep its own reference pixels,
    // otherwise a change made between two processed frames is diffed against itself and lost.
    [Fact]
    public void Tracker_SameBufferMutatedInPlace_StillDetectsChange()
    {
        const int w = 128, h = 128;
        var bgra = new byte[w * h * 4];
        Array.Fill(bgra, (byte)40);
        using var enc = new CpuTileEncoder { KeyframeInterval = 1000 };
        Assert.NotNull(enc.Encode(bgra, w, h, 0)); // first frame: full

        for (var i = 0; i < 4; i++) bgra[(70 * w + 70) * 4 + i] = 200; // pixel in tile (1,1)
        var probe = enc.Probe(bgra, w, h, new[] { new System.Drawing.Rectangle(70, 70, 1, 1) });
        Assert.Equal(1, probe.DirtyTiles);
        Assert.NotNull(enc.Encode(bgra, w, h, 1));
        Assert.Equal(0, enc.Probe(bgra, w, h, new[] { new System.Drawing.Rectangle(70, 70, 1, 1) }).DirtyTiles);
    }

    [Fact]
    public void Tracker_DirtyRectsLimitWhichTilesAreCompared()
    {
        const int w = 128, h = 128;
        var bgra = new byte[w * h * 4];
        Array.Fill(bgra, (byte)40);
        using var enc = new CpuTileEncoder { KeyframeInterval = 1000 };
        enc.Encode(bgra, w, h, 0);

        bgra[(10 * w + 10) * 4] = 255;               // change in tile (0,0)
        var probe = enc.Probe(bgra, w, h, new[] { new System.Drawing.Rectangle(100, 100, 4, 4) });
        Assert.Equal(0, probe.DirtyTiles);           // capture said elsewhere: trusted, not compared
        // Unknown dirty (null) compares everything and finds it.
        Assert.Equal(1, enc.Probe(bgra, w, h, null).DirtyTiles);
    }

    [Fact]
    public void Tracker_ChangeNotCommitted_IsCarriedToNextProbe()
    {
        const int w = 128, h = 128;
        var bgra = new byte[w * h * 4];
        Array.Fill(bgra, (byte)40);
        using var enc = new CpuTileEncoder { KeyframeInterval = 1000 };
        enc.Encode(bgra, w, h, 0);

        bgra[(10 * w + 10) * 4] = 255;
        var first = enc.Probe(bgra, w, h, new[] { new System.Drawing.Rectangle(10, 10, 1, 1) });
        Assert.Equal(1, first.DirtyTiles);           // frame skipped: neither Encode nor NotePresented
        // Next frame reports only a different region; the earlier change must not be forgotten.
        var next = enc.Probe(bgra, w, h, new[] { new System.Drawing.Rectangle(100, 100, 4, 4) });
        Assert.Equal(1, next.DirtyTiles);
    }

    [Fact]
    public void Capture_MergeCombinesDroppedAndNewerRegions()
    {
        var a = new[] { new System.Drawing.Rectangle(0, 0, 4, 4) };
        var b = new[] { new System.Drawing.Rectangle(8, 8, 4, 4) };
        Assert.Equal(2, Afterscreen.Sender.Capture.CapturedFrame.Merge(a, b)!.Count);
        Assert.Null(Afterscreen.Sender.Capture.CapturedFrame.Merge(null, b));
        Assert.Null(Afterscreen.Sender.Capture.CapturedFrame.Merge(a, null));
    }

    [Fact]
    public void MacBitrate_ClampsLikePathPolicy()
    {
        Assert.Equal(20_000_000, EncodeServices.MacBitrate(0));
        Assert.Equal(20_000_000, EncodeServices.MacBitrate(0.01));
        Assert.Equal(200_000_000, EncodeServices.MacBitrate(10));
        Assert.Equal(40_000_000, EncodeServices.MacBitrate(0.1));
    }

    [Fact]
    public void MacVideoPixels_Picks1440pBoxForHighBitrate()
    {
        var stream = new PixelSize(2880, 1620);
        var px = EncodeServices.MacVideoPixels(stream, 40_000_000, 30);
        Assert.Equal(2560, px.Width);
        Assert.Equal(1440, px.Height);
    }

    [Fact]
    public void StreamResolution_AutoPicksReducedOnSlowLink()
    {
        var panel = new PixelSize(5120, 2880);
        var source = new PixelSize(5120, 2880);
        Assert.Equal("panel", EncodeServices.ResolveStreamResolution("panel", panel, source, 0.1));
        Assert.Equal("reduced", EncodeServices.ResolveStreamResolution("reduced", panel, source, 10));
        // 5K full settle needs ~0.47 Gbps; 0.1 Gbps → reduced
        Assert.Equal("reduced", EncodeServices.ResolveStreamResolution("auto", panel, source, 0.1));
        Assert.Equal("panel", EncodeServices.ResolveStreamResolution("auto", panel, source, 1.0));
        Assert.True(EncodeServices.FullScreenGbps(panel) > 0.4 && EncodeServices.FullScreenGbps(panel) < 0.5);
    }
}
