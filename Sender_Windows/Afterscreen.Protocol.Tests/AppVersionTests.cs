using Afterscreen.Protocol;
using Xunit;

namespace Afterscreen.Protocol.Tests;

public class AppVersionTests
{
    [Fact]
    public void TagsReadAsVersions()
    {
        Assert.Equal(new[] { 1, 2, 3 }, AppVersion.Parts("v1.2.3"));
        Assert.Equal(new[] { 1, 10 }, AppVersion.Parts("1.10"));
        Assert.Null(AppVersion.Parts("v1.2.3-beta"));
        Assert.Null(AppVersion.Parts("1..2"));
        Assert.Null(AppVersion.Parts("1.2.3.4"));
        Assert.Null(AppVersion.Parts("+1.2"));
    }

    [Fact]
    public void NewerComparesNumbers()
    {
        Assert.True(AppVersion.IsNewer("v1.10.0", "1.9.9"));
        Assert.True(AppVersion.IsNewer("v1.1.0", "1.0.0"));
        Assert.False(AppVersion.IsNewer("v1.1", "1.1.0"));
        Assert.False(AppVersion.IsNewer("v1.0.0", "1.1.0"));
        Assert.False(AppVersion.IsNewer("junk", "1.0.0"));
    }
}
