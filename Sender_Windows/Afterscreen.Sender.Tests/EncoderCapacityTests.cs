using Afterscreen.Protocol;
using Afterscreen.Sender.Encode;
using Xunit;

namespace Afterscreen.Sender.Tests;

/// <summary>Mac PathPolicy.videoBoxes: layer sizes the bitrate fills at 0.15 bits per pixel per frame, largest first.</summary>
public class EncoderCapacityTests
{
    private static readonly PixelSize Max4k = new(3840, 2160);
    private static readonly PixelSize Max1440 = new(2560, 1440);

    [Fact]
    public void HevcAtAHighBitrateOffers4kThenSmaller()
    {
        var boxes = EncoderCapacity.VideoBoxes(80_000_000, VideoCodec.hevc, 60, Max4k);
        Assert.Equal(new[] { (3840, 2160), (2560, 1440), (1920, 1080) }, boxes.Select(b => (b.Width, b.Height)).ToArray());
    }

    [Fact]
    public void H264SkipsFourK()
    {
        var boxes = EncoderCapacity.VideoBoxes(80_000_000, VideoCodec.h264, 60, Max4k);
        Assert.Equal((2560, 1440), (boxes[0].Width, boxes[0].Height));
    }

    [Fact]
    public void ALowBitrateDropsTheBigBoxes()
    {
        // 20 Mbps / 60 fps = 333 kbit per frame: 0.16 bits per pixel only fits 1080p (2.07 Mpixel) - 1440p needs 553 kbit
        var boxes = EncoderCapacity.VideoBoxes(20_000_000, VideoCodec.hevc, 60, Max4k);
        Assert.Equal(new[] { (1920, 1080) }, boxes.Select(b => (b.Width, b.Height)).ToArray());
    }

    [Fact]
    public void WindowsCapsTheLayer()
    {
        var boxes = EncoderCapacity.VideoBoxes(200_000_000, VideoCodec.hevc, 60, Max1440);
        Assert.Equal((2560, 1440), (boxes[0].Width, boxes[0].Height));
    }

    [Fact]
    public void ACapThatIsNotAMacBoxIsTheLargestBox()
    {
        // Windows default cap 2880x1620: it leads the list, then the Mac boxes below it
        var boxes = EncoderCapacity.VideoBoxes(80_000_000, VideoCodec.hevc, 60, new PixelSize(2880, 1620));
        Assert.Equal(new[] { (2880, 1620), (2560, 1440), (1920, 1080) }, boxes.Select(b => (b.Width, b.Height)).ToArray());
    }
}
