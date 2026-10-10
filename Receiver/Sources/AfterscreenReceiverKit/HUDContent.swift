import CoreGraphics
import AfterscreenCore

/// What the HUD shows of a session: the sender's latest numbers, this Mac's, and a minute of history
public struct HUDTelemetry {
    public var sender: SenderStats?
    public var receiver: ReceiverStats?
    public var deband: Deband?
    public var throughput = History(capacity: 60)
    public var latency = History(capacity: 60)
    public var shownFPS = History(capacity: 60)

    public init() {}
}

/// HUD text: the popover's Connection, Picture and Resources cards without their controls
struct HUDContent: Equatable {
    enum Tone: Equatable { case plain, good, warn, bad }
    enum GraphColor: Equatable { case green, blue, purple }

    struct Row: Equatable {
        var label: String
        var value: String
        /// Drawn as the link's symbol before the value
        var link: LinkKind?
        var tone = Tone.plain
        var graph: [Double]?
        var graphColor = GraphColor.green
    }

    struct Section: Equatable {
        var title: String
        var rows: [Row]
    }

    var title: String
    var status: String
    var testing: Bool
    var sections: [Section]
    /// The folded HUD's one line: shown fps, throughput, latency and link quality
    var summary: String

    static let empty = HUDContent(title: "Afterscreen", status: "", testing: false, sections: [], summary: "")

    static func make(peer: String?, config: StreamConfig, telemetry t: HUDTelemetry) -> HUDContent {
        let dash = "—"
        let s = t.sender, r = t.receiver
        func fps(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? dash }
        func usage(cpu: Double, memory: UInt64, gpu: Double) -> String {
            "\(Format.percent(cpu)) · \(Format.bytes(memory)) · \(Format.percent(gpu))"
        }

        var connection = [
            Row(label: L10n.t("Link", "링크"), value: "\(LinkLabel.name(config.linkKind)) · \(s?.interface ?? dash)", link: config.linkKind),
            Row(label: L10n.t("Throughput", "전송량"),
                value: s.map { Format.gbps(bytesPerSecond: $0.throughputBitsPerSecond / 8) } ?? dash,
                graph: s == nil ? nil : t.throughput.values, graphColor: .green),
            Row(label: L10n.t("Measured link speed", "링크 실측 속도"), value: s?.capacityGbps.map { String(format: "%.2f Gbps", $0) } ?? dash),
            Row(label: L10n.t("Latency", "지연"), value: s?.latencyMs.map(Format.ms) ?? dash,
                graph: s == nil ? nil : t.latency.values, graphColor: .blue),
            Row(label: L10n.t("Jitter", "지연 변동"), value: s.map { Format.ms($0.jitterMs) } ?? dash),
            Row(label: L10n.t("Retransmits", "재전송"), value: s.map { String(format: "%.2f%%", $0.retransmitPercent) } ?? dash),
            Row(label: L10n.t("Link quality", "링크 품질"), value: s?.cableScore.map { "\($0) / 100" } ?? dash,
                tone: s?.cableScore.map { tone(ScoreBand($0)) } ?? .plain),
        ]
        if let mtu = s?.mtu {
            let advice = LinkLabel.mtuAdvice(mtu: mtu, link: config.linkKind)
            connection.append(Row(label: "MTU", value: advice.map { "\(mtu) · \($0)" } ?? "\(mtu)", tone: advice == nil ? .plain : .warn))
        }

        let motion = config.video.map(MotionLabel.video) ?? MotionLabel.text(path: config.path, lossyTiles: s?.lossyTiles ?? 0) ?? dash
        let picture = [
            Row(label: L10n.t("Frames: captured · sent · shown", "프레임: 캡처 · 전송 · 표시"),
                value: "\(fps(s?.captureFPS)) · \(fps(s?.sentFPS)) · \(fps(r?.displayedFPS))",
                graph: t.shownFPS.values, graphColor: .purple),
            Row(label: L10n.t("Dropped / min", "버린 프레임/분"), value: s.map { "\($0.droppedPerMinute)" } ?? dash),
            Row(label: L10n.t("Resolution", "해상도"), value: "\(config.streamPixels.width)×\(config.streamPixels.height)"),
            Row(label: L10n.t("Moving areas", "움직이는 영역"), value: motion),
            Row(label: L10n.t("Changed area", "바뀐 영역"), value: s.map { String(format: "%.0f%%", $0.dirtyPercent) } ?? dash),
            Row(label: L10n.t("Compression", "압축률"),
                value: s.map { $0.compressionRatio > 0 ? String(format: "%.1f×", $0.compressionRatio) : dash } ?? dash),
            Row(label: L10n.t("Smooth gradients", "계단 완화"), value: t.deband.map(DebandLabel.name) ?? dash),
            Row(label: L10n.t("Encode time", "인코딩 시간"), value: s.map { Format.ms($0.encodeMs) } ?? dash),
        ]

        let resources = [
            Row(label: L10n.t("Sending Mac: CPU · RAM · GPU", "보내는 Mac: CPU · 메모리 · GPU"),
                value: s.map { usage(cpu: $0.cpuPercent, memory: $0.memoryBytes, gpu: $0.gpuPercent) } ?? dash),
            Row(label: L10n.t("This Mac: CPU · RAM · GPU", "이 Mac: CPU · 메모리 · GPU"),
                value: r.map { usage(cpu: $0.cpuPercent, memory: $0.memoryBytes, gpu: $0.gpuPercent) } ?? dash),
            Row(label: L10n.t("Upload · decompress", "업로드 · 압축 해제"),
                value: r.map { "\(Format.ms($0.uploadMs)) · \(Format.ms($0.decompressMs))" } ?? dash),
        ]

        var summary = ["\(fps(r?.displayedFPS)) fps"]
        if let s = s {
            summary.append(Format.gbps(bytesPerSecond: s.throughputBitsPerSecond / 8))
            if let ms = s.latencyMs { summary.append(Format.ms(ms)) }
            if let score = s.cableScore { summary.append(L10n.t("quality \(score)", "품질 \(score)")) }
        }

        return HUDContent(
            title: peer ?? "Afterscreen",
            status: config.test ? L10n.t("Quality test", "품질 테스트") : L10n.t("Streaming", "스트리밍 중"),
            testing: config.test,
            sections: [
                Section(title: L10n.t("Connection", "연결"), rows: connection),
                Section(title: L10n.t("Picture", "화면"), rows: picture),
                Section(title: L10n.t("Resources", "자원 사용"), rows: resources),
            ],
            summary: summary.joined(separator: " · "))
    }

    private static func tone(_ band: ScoreBand) -> Tone {
        switch band {
        case .good: return .good
        case .fair: return .warn
        case .poor: return .bad
        }
    }
}

/// HUD frame at a corner of the stream view, origin bottom left
enum HUDPlacement {
    static let side: CGFloat = 16
    static let bottom: CGFloat = 16
    /// Clears the streamed desktop's menu bar: 24 pt, about 36 on a desktop scaled up 1.5×
    static let top: CGFloat = 52

    static func frame(size: CGSize, corner: ReceiverSettings.HUDCorner, in bounds: CGRect) -> CGRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let upper = corner == .topLeft || corner == .topRight
        let x = left ? bounds.minX + side : bounds.maxX - side - size.width
        let y = upper ? max(bounds.minY + bottom, bounds.maxY - top - size.height) : bounds.minY + bottom
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Corner of the screen quarter holding the HUD's centre
    static func nearest(to frame: CGRect, in bounds: CGRect) -> ReceiverSettings.HUDCorner {
        switch (frame.midX < bounds.midX, frame.midY >= bounds.midY) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
