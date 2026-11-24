using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class QualityNoticeTests
{
    [Fact]
    public void ShortDipsPassUnannounced()
    {
        var n = new QualityNotice();
        double? last = null;
        for (var i = 0; i < 4; i++) Assert.False(n.Update(30, 80, i, ref last));     // 4 s at 37%: not yet
        Assert.False(n.Update(80, 80, 4, ref last));
        Assert.False(n.Lowered);
    }

    [Fact]
    public void SevereAndLastingAnnouncesOnceThenEndsAfterRecovery()
    {
        var n = new QualityNotice();
        double? last = null;
        var shown = 0;
        for (var i = 0; i < 10; i++) if (n.Update(30, 80, i, ref last)) shown++;
        Assert.Equal(1, shown);
        Assert.True(n.Lowered);
        for (var i = 0; i < 29; i++) { n.Update(80, 80, 10 + i, ref last); Assert.True(n.Lowered); }
        n.Update(80, 80, 40, ref last);
        Assert.False(n.Lowered);                                  // 30 clear seconds end the episode
    }

    [Fact]
    public void AReconnectWithinTenMinutesStaysQuiet()
    {
        double? last = null;
        var first = new QualityNotice();
        for (var i = 0; i < 6; i++) first.Update(30, 80, 100 + i, ref last);
        var second = new QualityNotice();                          // new session, same process: lastShown carries over
        var shown = false;
        for (var i = 0; i < 6; i++) shown |= second.Update(30, 80, 300 + i, ref last);
        Assert.False(shown);
        Assert.True(second.Lowered);
    }
}
