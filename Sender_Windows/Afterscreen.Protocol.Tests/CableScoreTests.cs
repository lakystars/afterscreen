using Afterscreen.Protocol;

namespace Afterscreen.Protocol.Tests;

public class CableScoreTests
{
    [Fact]
    public void TileCapacityMatchesMac()
    {
        Assert.Equal(2.48, CableScore.TileCapacityGbps(5120, 2880, 60), precision: 2);
        Assert.Equal(0.35, CableScore.TileCapacityGbps(1920, 1080, 60), precision: 2);
        Assert.Equal(4.95, CableScore.TileCapacityGbps(5120, 2880, 120), precision: 2);
    }

    [Fact]
    public void CleanLinkIs100() =>
        Assert.Equal(100, CableScore.Score(0, 0, null, 0));

    [Fact]
    public void RetransmitAndJitterCapTheirPenalties()
    {
        Assert.Equal(60, CableScore.Score(10, 0, null, 0));   // min(40, 40)
        Assert.Equal(70, CableScore.Score(0, 10, null, 0));   // min(30, 30)
        Assert.Equal(30, CableScore.Score(10, 10, null, 0));
    }

    [Fact]
    public void CapacityShortfallTakesUpTo30()
    {
        Assert.Equal(85, CableScore.Score(0, 0, 1.0, 2.0));
        Assert.Equal(70, CableScore.Score(0, 0, 0.0, 2.0));
    }

    [Fact]
    public void RequiredGbpsUsesVideoWhenPresent()
    {
        var cfg = new StreamConfig
        {
            StreamPixels = new PixelSize(2880, 1620),
            FrameRate = 60,
            Video = new VideoLayer { Bitrate = 40_000_000 },
        };
        Assert.Equal(0.06, CableScore.RequiredGbps(cfg), precision: 5);
    }

    [Fact]
    public void BrightnessWireRoundTrip()
    {
        var encoded = BrightnessWire.Encode(new PanelLight(null, 0.75));
        var back = BrightnessWire.Decode(encoded);
        Assert.Null(back.Nits);
        Assert.Equal(0.75, back.Level, precision: 4);
    }

    [Fact]
    public void BrightnessOffsetMatchesMac()
    {
        Assert.Equal(0, BrightnessOffset.Snapped(0.04));
        Assert.Equal(0.5, BrightnessOffset.Snapped(0.5), precision: 4);
        Assert.Equal(1, BrightnessOffset.Gain(0), precision: 4);
        Assert.Equal(2, BrightnessOffset.Gain(1), precision: 4);
        Assert.Equal(0.5, BrightnessOffset.Gain(-1), precision: 4);
        Assert.Equal("0%", BrightnessOffset.Label(0));
        Assert.Equal("+100%", BrightnessOffset.Label(1));
        Assert.Equal("\u221250%", BrightnessOffset.Label(-1));
        Assert.True(BrightnessOffset.Level(0.5, 1) > 0.5);
        Assert.True(BrightnessOffset.Level(0.5, -1) < 0.5);
    }
}
