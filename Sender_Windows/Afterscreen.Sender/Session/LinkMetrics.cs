using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>Mac <c>LinkMetrics</c> helpers used by the Connection card.</summary>
public static class LinkMetrics
{
    /// <summary>Mac-to-Mac USB-C trained as USB NCM — tip when that link is active.</summary>
    public static string? UsbFallbackAdvice(LinkKind? link) =>
        link == LinkKind.usb
            ? "Connected as USB, not Thunderbolt. With a Thunderbolt cable, replug both ends; if it stays USB, sleep or restart either machine."
            : null;
}
