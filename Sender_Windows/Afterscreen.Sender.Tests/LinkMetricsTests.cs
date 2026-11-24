using Afterscreen.Protocol;
using Afterscreen.Sender.Session;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class LinkMetricsTests
{
    [Fact]
    public void UsbFallbackAdviceOnlyForUsb()
    {
        Assert.NotNull(LinkMetrics.UsbFallbackAdvice(LinkKind.usb));
        Assert.Null(LinkMetrics.UsbFallbackAdvice(LinkKind.thunderbolt));
        Assert.Null(LinkMetrics.UsbFallbackAdvice(LinkKind.ethernet));
        Assert.Null(LinkMetrics.UsbFallbackAdvice(null));
    }
}
