using Afterscreen.Sender.Encode;
using Xunit;

namespace Afterscreen.Sender.Tests;

/// <summary>Mac RateControl: backs off while the link queues, returns slowly, never past the start.</summary>
public class RateControlTests
{
    private static RateControl.Sample Calm() => new() { Frames = 60, SentBps = 50e6, RttMs = 2, Buffered = 1000 };

    [Fact]
    public void BacklogCutsTheBitrateByThirtyPercent()
    {
        var rc = new RateControl(80_000_000, 60);
        // 50 Mbps sent, 2 MB waiting = 0.32 s of stream, over the 0.15 s limit, and not shrinking
        var queued = new RateControl.Sample { Frames = 60, SentBps = 50e6, RttMs = 2, Buffered = 2_000_000 };
        var cut = rc.Update(queued);
        Assert.Equal(56_000_000, cut);
        Assert.Equal(56_000_000, rc.Bitrate);
    }

    [Fact]
    public void RecoversSlowlyAndStopsAtTheStart()
    {
        var rc = new RateControl(80_000_000, 60);
        var queued = new RateControl.Sample { Frames = 60, SentBps = 50e6, RttMs = 2, Buffered = 2_000_000 };
        rc.Update(queued); rc.Update(queued);
        var low = rc.Bitrate;
        Assert.True(low < 80_000_000);
        for (var i = 0; i < 2; i++) Assert.Null(rc.Update(Calm()));    // three clear seconds before the first step up
        Assert.NotNull(rc.Update(Calm()));
        for (var i = 0; i < 60; i++) rc.Update(Calm());
        Assert.Equal(80_000_000, rc.Bitrate);
    }

    [Fact]
    public void StillScreenProvesNothing()
    {
        var rc = new RateControl(80_000_000, 60);
        var idle = new RateControl.Sample { Frames = 2, SentBps = 1e6, RttMs = 200, Buffered = 5_000_000 };
        for (var i = 0; i < 10; i++) Assert.Null(rc.Update(idle));
        Assert.Equal(80_000_000, rc.Bitrate);
    }

    [Fact]
    public void FloorIsAnEighthOfTheStart()
    {
        var rc = new RateControl(80_000_000, 60);
        var queued = new RateControl.Sample { Frames = 60, SentBps = 50e6, RttMs = 2, Buffered = 2_000_000 };
        for (var i = 0; i < 40; i++) rc.Update(queued);
        Assert.Equal(10_000_000, rc.Bitrate);
    }
}
