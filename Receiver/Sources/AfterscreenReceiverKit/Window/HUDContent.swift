import CoreGraphics
import AfterscreenCore

/// HUD data: latest sender and receiver stats, a minute's history
public struct HUDTelemetry {
    public var sender: SenderStats?
    public var receiver: ReceiverStats?
    public var deband: Deband?
    public var throughput = History(capacity: 60)
    public var latency = History(capacity: 60)
    public var shownFPS = History(capacity: 60)

    public init() {}
}

/// HUD text: popover's Connection, Picture, Resources cards, no controls
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
    /// Folded HUD line: shown fps, throughput, latency, link quality
    var summary: String

    static let empty = HUDContent(title: "Afterscreen", status: "", testing: false, sections: [], summary: "")

    static func make(peer: String?, config: StreamConfig, telemetry t: HUDTelemetry) -> HUDContent {
        let dash = StatValue.dash
        let s = t.sender, r = t.receiver
        func fps(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? dash }

        var connection = [
            Row(label: StatName.link, value: "\(LinkLabel.name(config.linkKind)) · \(s?.interface ?? dash)", link: config.linkKind),
            Row(label: StatName.throughput, value: s.map { Format.gbps(bytesPerSecond: $0.throughputBitsPerSecond / 8) } ?? dash,
                graph: s == nil ? nil : t.throughput.values, graphColor: .green),
            Row(label: StatName.capacity, value: StatValue.capacity(s?.capacityGbps)),
            Row(label: StatName.latency, value: StatValue.latency(s?.latencyMs),
                graph: s == nil ? nil : t.latency.values, graphColor: .blue),
            Row(label: StatName.jitter, value: s.map { StatValue.latency($0.jitterMs) } ?? dash),
            Row(label: StatName.retransmits, value: s.map { StatValue.retransmits($0.retransmitPercent) } ?? dash),
            Row(label: StatName.quality, value: StatValue.quality(s?.cableScore), tone: s?.cableScore.map { tone(ScoreBand($0)) } ?? .plain),
        ]
        if let mtu = s?.mtu {
            let m = StatValue.mtu(mtu, link: config.linkKind)
            connection.append(Row(label: "MTU", value: m.text, tone: m.advised ? .warn : .plain))
        }

        // No stats yet: the layer's bitrate stands in
        let bitrate = s == nil ? config.video?.bitrate : s?.videoBitrate
        let motion = MotionLabel.text(config, videoBitrate: bitrate, lossyTiles: s?.lossyTiles ?? 0)
        var picture = [
            Row(label: StatName.frames, value: "\(fps(s?.captureFPS)) · \(fps(s?.sentFPS)) · \(fps(r?.displayedFPS))",
                graph: t.shownFPS.values, graphColor: .purple),
            Row(label: StatName.dropped, value: s.map { "\($0.droppedPerMinute)" } ?? dash),
            Row(label: StatName.resolution, value: StatValue.resolution(config.streamPixels)),
            Row(label: StatName.motion, value: motion),
        ]
        if let target = MotionLabel.target(config, videoBitrate: bitrate) {
            picture.append(Row(label: StatName.videoTarget, value: target))
        }
        picture += [
            Row(label: StatName.blocks, value: s.map { StatValue.blocks(percent: $0.dirtyPercent, in: config.streamPixels) } ?? dash),
            Row(label: StatName.compression, value: s.map { StatValue.compression($0.compressionRatio) } ?? dash),
            Row(label: StatName.deband, value: t.deband.map(DebandLabel.name) ?? dash),
            Row(label: StatName.encode, value: s.map { StatValue.encode($0.encodeMs) } ?? dash),
        ]

        let resources = [
            Row(label: peer ?? L10n.t("Sender", "송신기"),
                value: s.map { StatValue.usage(cpu: $0.cpuPercent, memory: $0.memoryBytes, gpu: $0.gpuPercent) } ?? dash),
            Row(label: ComputerName.current, value: r.map { StatValue.usage(cpu: $0.cpuPercent, memory: $0.memoryBytes, gpu: $0.gpuPercent) } ?? dash),
            Row(label: StatName.upload(ComputerName.current), value: r.map { StatValue.upload($0.uploadMs, decompress: $0.decompressMs) } ?? dash),
        ]

        var summary = ["\(fps(r?.displayedFPS)) fps"]
        if let s = s {
            summary.append(Format.gbps(bytesPerSecond: s.throughputBitsPerSecond / 8))
            if let ms = s.latencyMs { summary.append(StatValue.latency(ms)) }
            if let score = s.cableScore { summary.append(L10n.t("quality \(score)", "품질 \(score)")) }
        }

        return HUDContent(
            title: peer ?? "Afterscreen",
            status: config.test ? L10n.t("Quality test", "품질 테스트") : L10n.t("Streaming", "스트리밍 중"),
            testing: config.test,
            sections: [
                Section(title: StatName.connection, rows: connection),
                Section(title: StatName.picture, rows: picture),
                Section(title: StatName.resources, rows: resources),
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

/// HUD frame at a stream view corner; origin bottom left
enum HUDPlacement {
    static let side: CGFloat = 16
    static let bottom: CGFloat = 16
    /// Clears the streamed desktop's menu bar
    /// 24 pt; about 36 pt on a desktop scaled 1.5×
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
