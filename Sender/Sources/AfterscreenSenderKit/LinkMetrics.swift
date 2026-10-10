import AfterscreenCore

/// Link latency and jitter for the popover and cable score
enum LinkMetrics {
    /// Jumbo frames cut the packets per second a Thunderbolt or USB link must carry about sixfold
    static func mtuAdvice(mtu: Int?, link: LinkKind?) -> String? {
        guard let mtu = mtu, mtu < 9000, link == .thunderbolt || link == .usb else { return nil }
        return L10n.t("9000 recommended", "9000 권장")
    }

    /// Kernel smoothed RTT excludes frames queued ahead of pings; pings are the fallback
    static func latencyAndJitter(tcp: TCPInfo?, ping: LatencyStats) -> (latencyMs: Double?, jitterMs: Double) {
        if let tcp = tcp { return (tcp.rttMs, tcp.rttVarMs) }
        return (ping.last, ping.jitter)
    }
}
