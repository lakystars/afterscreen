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
}

/// How moving areas are sent
/// Tile path: tile encoding; hybrid path: video layer
public enum MotionLabel {
    /// `videoBitrate` nil with a video layer: encoder failed, BC1 instead
    public static func text(_ config: StreamConfig, videoBitrate: Int?, lossyTiles: Int) -> String {
        if let v = config.video, videoBitrate != nil { return video(v) }
        return lossyTiles == 0 ? L10n.t("BC7, sharp", "BC7 (선명)") : L10n.t("BC1 on \(lossyTiles) tiles", "BC1 · 타일 \(lossyTiles)개")
    }

    /// Encoder's target now; nil without a running video layer
    public static func target(_ config: StreamConfig, videoBitrate: Int?) -> String? {
        guard config.video != nil, let bitrate = videoBitrate else { return nil }
        return "\(bitrate / 1_000_000) Mbps"
    }

    public static func video(_ v: VideoLayer) -> String {
        "\(v.codec.rawValue.uppercased())\(v.tenBit ? L10n.t(" 10-bit", " 10비트") : "") · \(v.pixels.width)×\(v.pixels.height)"
    }
}

/// Receiver's hardware video decoders
/// BC7 is a texture format, not a decoder: left out
public enum HardwareDecodeLabel {
    public static func text(_ w: Welcome) -> String {
        let mark = { (on: Bool) in on ? "✓" : "✗" }
        let hevc = w.hevcDecode ? "✓ (" + L10n.t("10-bit", "10비트") + " \(mark(w.hevcMain10Decode)))" : "✗"
        return "HEVC \(hevc) · H.264 \(mark(w.h264Decode))"
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
    public static var dropped: String { L10n.t("Skipped / min", "건너뛴 프레임/분") }
    public static var resolution: String { L10n.t("Transfer resolution", "전송 해상도") }
    public static var motion: String { L10n.t("Motion sent as", "움직임 전송") }
    public static var videoTarget: String { L10n.t("Video target bitrate", "영상 목표 비트레이트") }
    public static var blocks: String { L10n.t("Changed blocks", "바뀐 블록") }
    public static var compression: String { L10n.t("Tile LZ4 ratio", "타일 LZ4 압축률") }
    public static var deband: String { L10n.t("Smoothing", "계단 완화") }
    public static var encode: String { L10n.t("Frame processing", "프레임 처리 시간") }
    /// Receiver's texture upload and decompression
    public static func upload(_ receiver: String) -> String { L10n.t("\(receiver): upload · decompress", "\(receiver): 업로드 · 압축 해제") }
}

/// Value text the popover and the HUD share
public enum StatValue {
    public static let dash = "—"

    /// Same units as throughput, which sits beside it
    public static func capacity(_ gbps: Double?) -> String { gbps.map { Format.gbps(bytesPerSecond: $0 * 1e9 / 8) } ?? dash }
    /// Kernel RTT comes in whole milliseconds
    public static func latency(_ ms: Double?) -> String {
        guard let ms = ms else { return dash }
        return ms < 1 ? "<1 ms" : String(format: "%.0f ms", ms)
    }
    /// 0: no new frame in the last second
    public static func encode(_ ms: Double) -> String { ms > 0 ? Format.ms(ms) : dash }
    public static func retransmits(_ percent: Double) -> String { String(format: "%.2f%%", percent) }
    public static func quality(_ score: Int?) -> String { score.map { "\($0) / 100" } ?? dash }
    /// Per frame, of all blocks; 1 at least if any
    public static func blocks(percent: Double, in size: PixelSize) -> String {
        let total = TileGeometry(width: size.width, height: size.height).tileCount
        // A peer's stray value stays in range
        let share = percent.isFinite ? min(100, percent) : 0
        let changed = share > 0 ? max(1, Int((share / 100 * Double(total)).rounded())) : 0
        return "\(changed)/\(total)"
    }
    public static func compression(_ ratio: Double) -> String { ratio > 0 ? String(format: "%.1f×", ratio) : dash }
    public static func resolution(_ p: PixelSize) -> String { "\(p.width)×\(p.height)" }

    public static func usage(cpu: Double, memory: UInt64, gpu: Double) -> String {
        "\(Format.percent(cpu)) · \(Format.bytes(memory)) · \(Format.percent(gpu))"
    }

    public static func upload(_ uploadMs: Double, decompress decompressMs: Double) -> String {
        "\(Format.ms(uploadMs)) · \(Format.ms(decompressMs))"
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
