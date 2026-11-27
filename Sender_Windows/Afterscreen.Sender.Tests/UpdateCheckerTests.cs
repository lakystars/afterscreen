using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class UpdateCheckerTests
{
    [Fact]
    public void OnlyPublishedVersionTagsCount()
    {
        Assert.Equal("v1.2.0", UpdateChecker.TagFrom("""{"tag_name":"v1.2.0","draft":false,"prerelease":false}"""));
        Assert.Null(UpdateChecker.TagFrom("""{"tag_name":"v1.2.0","prerelease":true}"""));
        Assert.Null(UpdateChecker.TagFrom("""{"tag_name":"nightly"}"""));
        Assert.Null(UpdateChecker.TagFrom("not json"));
    }

    [Fact]
    public void ThePageIsThisRepositorysRelease()
    {
        Assert.Equal("https://github.com/lakystars/afterscreen/releases/tag/v1.2.0",
            UpdateChecker.PageFor("v1.2.0")?.AbsoluteUri);
    }

    [Fact]
    public void UpdateNamesTheSidesItUpdates()
    {
        Assert.True(UpdateChecker.Update("v1.2.0", "1.1.0", null)?.Windows);
        Assert.False(UpdateChecker.Update("v1.2.0", "1.1.0", null)?.Receiver);
        var both = UpdateChecker.Update("v1.2.0", "1.1.0", "1.0.0");
        Assert.Equal(new[] { true, true }, new[] { both!.Windows, both.Receiver });
        Assert.Equal("1.2.0", both.Version);
        var recvOnly = UpdateChecker.Update("v1.1.0", "1.1.0", "1.0.0");
        Assert.Equal(new[] { false, true }, new[] { recvOnly!.Windows, recvOnly.Receiver });
        Assert.Null(UpdateChecker.Update("v1.1.0", "1.1.0", "1.1.0"));
        Assert.Null(UpdateChecker.Update("v1.1.0", null, null));
    }
}
