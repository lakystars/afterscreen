/// Stat wording shared by the sender popover and the receiver HUD

public enum LinkLabel {
    public static func glyph(_ kind: LinkKind?) -> String {
        switch kind {
        case .thunderbolt?: return "ϟ"
        case .usb?: return "⌁"
        case .ethernet?: return "⇄"
        case .wifi?: return "≋"
        case .loopback?: return "↺"
        default: return "?"
        }
    }

    public static func name(_ kind: LinkKind?) -> String {
        switch kind {
        case .thunderbolt?: return "Thunderbolt"
        case .usb?: return "USB"
        case .ethernet?: return L10n.t("Ethernet", "이더넷")
        case .wifi?: return "Wi-Fi"
        case .loopback?: return L10n.t("Loopback (same Mac)", "루프백(같은 Mac)")
        case .unsupported?: return L10n.t("Unsupported", "지원 안 함")
        case nil: return "—"
        }
    }

    /// SF Symbol for the link; Ethernet's arrows are the ones macOS Network settings show
    public static func symbol(_ kind: LinkKind?) -> String? {
        switch kind {
        case .thunderbolt?: return "bolt.fill"
        case .usb?: return "cable.connector"
        case .ethernet?: return "arrow.left.arrow.right"
        case .wifi?: return "wifi"
        case .loopback?: return "arrow.triangle.2.circlepath"
        case .unsupported?: return "questionmark"
        case nil: return nil
        }
    }

    /// Jumbo frames cut the packets per second a Thunderbolt or USB link must carry about sixfold
    public static func mtuAdvice(mtu: Int?, link: LinkKind?) -> String? {
        guard let mtu = mtu, mtu < 9000, link == .thunderbolt || link == .usb else { return nil }
        return L10n.t("9000 recommended", "9000 권장")
    }
}

/// How moving areas are sent: tile encoding on the tile path, the video layer on the hybrid path
public enum MotionLabel {
    public static func text(path: StreamPath, lossyTiles: Int) -> String? {
        guard path == .tile else { return nil }
        return lossyTiles == 0 ? L10n.t("BC7, sharp", "BC7 (선명)") : L10n.t("BC1 on \(lossyTiles) tiles", "BC1 · 타일 \(lossyTiles)개")
    }

    public static func video(_ v: VideoLayer) -> String {
        "\(v.codec.rawValue.uppercased())\(v.tenBit ? L10n.t(" 10-bit", " 10비트") : "") \(v.pixels.width)×\(v.pixels.height) · \(v.bitrate / 1_000_000) Mbps"
    }
}

public enum DebandLabel {
    public static func name(_ level: Deband) -> String {
        switch level {
        case .off: return L10n.t("Off", "끄기")
        case .weak: return L10n.t("Low", "약하게")
        case .normal: return L10n.t("Medium", "보통")
        case .strong: return L10n.t("High", "강하게")
        }
    }
}

/// Link quality colour bands; no score yet reads as good
public enum ScoreBand: Equatable {
    case good, fair, poor

    public init(_ score: Int?) {
        let s = score ?? 100
        self = s >= 80 ? .good : (s >= 50 ? .fair : .poor)
    }
}
