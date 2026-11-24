using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class DiscoveryTests
{
    [Fact]
    public void RetryDelayIsTheMacBackoff()
    {
        // Mac Discovery.retryDelay: 2 s, doubling to 15 s
        Assert.Equal(new double[] { 2, 4, 8, 15, 15, 15 }, Enumerable.Range(0, 6).Select(i => Discovery.RetryDelay(i).TotalSeconds).ToArray());
    }
}
