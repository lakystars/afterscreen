using Afterscreen.Protocol;
using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class QualityTestTests
{
    [Fact]
    public void StagesAreFractionsOfThePanelAlignedToFour()
    {
        var sizes = QualityTest.Stages(new PixelSize(5120, 2880));
        Assert.Equal(new[] { (1920, 1080), (2560, 1440), (3840, 2160), (5120, 2880) }, sizes.Select(s => (s.Width, s.Height)).ToArray());
        Assert.All(QualityTest.Stages(new PixelSize(2880, 1800)), s => { Assert.Equal(0, s.Width % 4); Assert.Equal(0, s.Height % 4); });
    }

    [Fact]
    public void VerdictIsTheLargestSmoothStage()
    {
        var stages = new List<QualityTest.Stage>
        {
            new() { Size = new PixelSize(1920, 1080), Fps = 60 },
            new() { Size = new PixelSize(2560, 1440), Fps = 59 },
            new() { Size = new PixelSize(3840, 2160), Fps = 40 },
            new() { Size = new PixelSize(5120, 2880), Fps = 55.5 },   // smooth (55 of 60) and the largest
        };
        Assert.Equal(5120, QualityTest.Verdict(stages, 60)!.Size.Width);
        stages[3].Fps = 54;
        Assert.Equal(2560, QualityTest.Verdict(stages, 60)!.Size.Width);
        Assert.Null(QualityTest.Verdict(stages.Select(s => new QualityTest.Stage { Size = s.Size, Fps = 10 }).ToList(), 60));
    }

    [Fact]
    public void SmoothAndLabelsFollowTheMac()
    {
        Assert.Equal(110, QualityTest.SmoothFps(120), 6);
        Assert.Equal("5K", QualityTest.Label(new PixelSize(5120, 2880)));
        Assert.Equal("4K", QualityTest.Label(new PixelSize(3840, 2160)));
        Assert.Equal("1440p", QualityTest.Label(new PixelSize(2560, 1440)));
        Assert.True(QualityTest.Warmup(new PixelSize(5120, 2880), 0.9) <= 5);
    }

    [Fact]
    public void CaptionMatchesMacEnglishTestCard()
    {
        Assert.Equal("Wi-Fi · 1440p · 2/5 · Full motion",
            QualityTest.Caption(new PixelSize(2560, 1440), LinkKind.wifi, 2, 5, typical: false));
        Assert.Equal("Ethernet · Typical use · 4096×2304 · 5/5",
            QualityTest.Caption(new PixelSize(4096, 2304), LinkKind.ethernet, 5, 5, typical: true));
        Assert.Equal("Loopback", QualityTest.LinkName(LinkKind.loopback));
    }
}
