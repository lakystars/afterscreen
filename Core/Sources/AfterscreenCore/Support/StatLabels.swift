/// Stat wording shared by sender popover and receiver HUD

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

    /// SF Symbol for the link
    /// Ethernet arrows match macOS Network settings
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

    /// Jumbo frames cut Thunderbolt/USB packet rate about sixfold
    public static func mtuAdvice(mtu: Int?, link: LinkKind?) -> String? {
        guard let mtu = mtu, mtu < 9000, link == .thunderbolt || link == .usb else { return nil }
        return L10n.t("9000 recommended", "9000 권장")
    }
}

/// How moving areas are sent
/// Tile path: tile encoding; hybrid path: video layer
public enum MotionLabel {
    public static func text(path: StreamPath, lossyTiles: Int) -> String? {
        guard path == .tile else { return nil }
        return lossyTiles == 0 ? L10n.t("BC7, sharp", "BC7 (선명)") : L10n.t("BC1 on \(lossyTiles) tiles", "BC1 · 타일 \(lossyTiles)개")
    }

    /// `bitrate`: the encoder's now; the layer's from the probe
    public static func video(_ v: VideoLayer, bitrate: Int? = nil) -> String {
        "\(v.codec.rawValue.uppercased())\(v.tenBit ? L10n.t(" 10-bit", " 10비트") : "") \(v.pixels.width)×\(v.pixels.height) · \((bitrate ?? v.bitrate) / 1_000_000) Mbps"
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

/// Field and section names the popover and the HUD share
public enum StatName {
    public static var connection: String { L10n.t("Connection", "연결") }
    public static var picture: String { L10n.t("Picture", "화면") }
    /// Its rows: each Mac by name, then the receiver's upload
    public static var resources: String { L10n.t("Resources · CPU · RAM · GPU", "자원 사용 · CPU · 메모리 · GPU") }

    public static var link: String { L10n.t("Link", "링크") }
    public static var throughput: String { L10n.t("Throughput", "전송량") }
    public static var capacity: String { L10n.t("Measured link speed", "링크 실측 속도") }
    public static var latency: String { L10n.t("Latency", "지연") }
    public static var jitter: String { L10n.t("Jitter", "지연 변동") }
    public static var retransmits: String { L10n.t("Retransmits", "재전송") }
    public static var quality: String { L10n.t("Link quality", "링크 품질") }
    public static var frames: String { L10n.t("Frames: captured · sent · shown", "프레임: 캡처 · 전송 · 표시") }
    public static var dropped: String { L10n.t("Dropped / min", "버린 프레임/분") }
    public static var resolution: String { L10n.t("Resolution", "해상도") }
    public static var motion: String { L10n.t("Moving areas", "움직이는 영역") }
    public static var changed: String { L10n.t("Changed area", "바뀐 영역") }
    public static var compression: String { L10n.t("Compression", "압축률") }
    public static var deband: String { L10n.t("Smooth gradients", "계단 완화") }
    public static var encode: String { L10n.t("Encode time", "인코딩 시간") }
    /// Receiver's texture upload and decompression
    public static func upload(_ receiver: String) -> String { L10n.t("\(receiver): upload · decompress", "\(receiver): 업로드 · 압축 해제") }
}

/// Value text the popover and the HUD share
public enum StatValue {
    public static let dash = "—"

    public static func capacity(_ gbps: Double?) -> String { gbps.map { String(format: "%.2f Gbps", $0) } ?? dash }
    public static func retransmits(_ percent: Double) -> String { String(format: "%.2f%%", percent) }
    public static func quality(_ score: Int?) -> String { score.map { "\($0) / 100" } ?? dash }
    public static func changed(_ percent: Double) -> String { String(format: "%.0f%%", percent) }
    public static func compression(_ ratio: Double) -> String { ratio > 0 ? String(format: "%.1f×", ratio) : dash }
    public static func resolution(_ p: PixelSize) -> String { "\(p.width)×\(p.height)" }

    public static func usage(cpu: Double, memory: UInt64, gpu: Double) -> String {
        "\(Format.percent(cpu)) · \(Format.bytes(memory)) · \(Format.percent(gpu))"
    }

    public static func upload(_ uploadMs: Double, decompress decompressMs: Double) -> String {
        "\(Format.ms(uploadMs)) · \(Format.ms(decompressMs))"
    }

    /// MTU with the jumbo frame advice, where it applies
    public static func mtu(_ mtu: Int, link: LinkKind?) -> (text: String, advised: Bool) {
        let advice = LinkLabel.mtuAdvice(mtu: mtu, link: link)
        return (advice.map { "\(mtu) · \($0)" } ?? "\(mtu)", advice != nil)
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
