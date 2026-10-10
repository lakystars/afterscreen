import AfterscreenCore

/// Link latency and jitter for the popover and cable score
enum LinkMetrics {
    /// Mac-to-Mac USB-C link trained as USB NCM
    /// Port can stay so until replug, sleep or restart
    static func usbFallbackAdvice(link: LinkKind?) -> String? {
        guard link == .usb else { return nil }
        return L10n.t("Connected as USB, not Thunderbolt. With a Thunderbolt cable, replug both ends; if it stays USB, sleep or restart either Mac.",
                      "Thunderbolt가 아닌 USB로 연결됐습니다. Thunderbolt 케이블이면 양쪽을 뽑았다 다시 꽂고, 계속 USB이면 한쪽 Mac을 잠자기하거나 재시동하세요.")
    }

    /// Kernel smoothed RTT excludes frames queued ahead of pings
    /// Pings are the fallback
    static func latencyAndJitter(tcp: TCPInfo?, ping: LatencyStats) -> (latencyMs: Double?, jitterMs: Double) {
        if let tcp = tcp { return (tcp.rttMs, tcp.rttVarMs) }
        return (ping.last, ping.jitter)
    }
}
