using Afterscreen.Protocol;
using Afterscreen.Sender.Encode;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class PathPolicyTests
{
    private static Welcome Welcome(bool hevc = true) => new()
    {
        ProtocolVersion = 1,
        Name = "t",
        HevcDecode = hevc,
        H264Decode = true,
        HevcMain10Decode = hevc,
        Bc7 = true,
        PanelPixels = new PixelSize(5120, 2880),
        PanelPoints = new PixelSize(2560, 1440),
    };

    [Fact]
    public void RelinkKeepsStreamSizeAndRaisesBitrateOnFasterLink()
    {
        var current = new StreamConfig
        {
            Path = StreamPath.hybrid,
            StreamPixels = new PixelSize(1920, 1200),
            Video = new VideoLayer
            {
                Codec = VideoCodec.hevc,
                Pixels = new PixelSize(1920, 1080),
                Bitrate = 20_000_000,
                TenBit = true,
            },
            LinkKind = LinkKind.wifi,
            FrameRate = 60,
        };
        // Below tile floor (~0.39 Gbps at 1920×1200×60): stay hybrid, raise MeanBitRate floor.
        var next = PathPolicy.Relink(current, LinkKind.ethernet, capacityGbps: 0.25, Welcome());
        Assert.Equal(1920, next.StreamPixels.Width);
        Assert.Equal(LinkKind.ethernet, next.LinkKind);
        Assert.Equal(StreamPath.hybrid, next.Path);
        Assert.NotNull(next.Video);
        Assert.True(next.Video!.Bitrate > current.Video!.Bitrate);
        Assert.Equal(1920, next.Video.Pixels.Width);
    }

    [Fact]
    public void RelinkToTilesWhenWiredCapacityIsEnough()
    {
        var current = new StreamConfig
        {
            Path = StreamPath.hybrid,
            StreamPixels = new PixelSize(1920, 1080),
            Video = new VideoLayer { Codec = VideoCodec.hevc, Pixels = new PixelSize(1920, 1080), Bitrate = 40_000_000, TenBit = true },
            LinkKind = LinkKind.wifi,
            FrameRate = 60,
        };
        // 1920x1080@60 * 2.8 bpp ≈ 0.35 Gbps needed; 2 Gbps is enough for tiles.
        var next = PathPolicy.Relink(current, LinkKind.ethernet, capacityGbps: 2.0, Welcome());
        Assert.Equal(StreamPath.tile, next.Path);
        Assert.Null(next.Video);
    }
}
