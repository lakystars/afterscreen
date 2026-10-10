import AppKit
import AfterscreenCore
import SwiftUI

/// Link menu entries: links that answer now, then a pinned link that stopped answering
enum LinkMenu {
    struct Choice {
        var kind: LinkKind
        var reachable: Bool
    }

    static func choices(available: [LinkKind], pinned: LinkKind?) -> [Choice] {
        var list = available.map { Choice(kind: $0, reachable: true) }
        if let pinned = pinned, !available.contains(pinned) { list.append(Choice(kind: pinned, reachable: false)) }
        return list
    }
}

extension Format {
    /// Four characters, left-padded with figure spaces: a changing digit count would move the status item and its open popover
    static func compactGbps(_ bitsPerSecond: Double) -> String {
        let text: String
        switch bitsPerSecond {
        case 10e9...: text = String(format: "%.0fG", bitsPerSecond / 1e9)
        case 1e9...: text = String(format: "%.1fG", bitsPerSecond / 1e9)
        default: text = String(format: "%.0fM", bitsPerSecond / 1e6)
        }
        return String(repeating: "\u{2007}", count: max(0, 4 - text.count)) + text
    }
}

/// Menu bar item text: the icon, the link glyph while streaming, and optionally fps and throughput at a fixed width
enum StatusTitle {
    static func text(_ s: SenderSnapshot, stats: Bool) -> String {
        guard s.isStreaming else { return "▭" }
        let glyph = "▭ \(LinkLabel.glyph(s.link))"
        guard stats else { return glyph }
        let fps = String(Int(s.sentFPS.rounded()))
        return glyph + " " + String(repeating: "\u{2007}", count: max(0, 2 - fps.count)) + fps + "fps · " + Format.compactGbps(s.throughputBitsPerSecond)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1, let top = values.max(), top > 0 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / top)))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, lineWidth: 1.3)
        }
        .frame(width: 64, height: 14)
    }
}

/// Label, value and an optional trailing view; `help` explains the field on hover
private struct Row<Trailing: View>: View {
    var label: String
    var value: String
    var valueColor: Color = .primary
    var help: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(valueColor)
            trailing()
        }
        .font(.system(size: 12))
        .help(help ?? "")
    }
}

private extension Row where Trailing == EmptyView {
    init(_ label: String, _ value: String, color: Color = .primary, help: String? = nil) {
        self.init(label: label, value: value, valueColor: color, help: help) { EmptyView() }
    }
}

/// A titled group on a tinted background, so sections read apart
private struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// Sound on the iMac: the switch, then the volume while the iMac plays it
private struct SoundCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SenderSettings

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        let s = model.snapshot
        Card(title: L10n.t("iMac sound", "iMac 소리")) {
            Toggle(L10n.t("Play this Mac's sound on the iMac", "이 Mac의 소리를 iMac에서 재생"), isOn: $settings.sound)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .help(L10n.t("This Mac stays silent while the iMac plays. Asks once for System Audio Recording permission. About 1.5 Mbps",
                             "iMac에서 재생하는 동안 이 Mac 스피커는 소리가 나지 않습니다. 처음 한 번 시스템 오디오 녹음 권한을 묻습니다. 약 1.5Mbps를 씁니다"))
            if settings.sound, s.soundOnReceiver, let level = model.volume {
                HStack(spacing: 8) {
                    Image(systemName: level > 0 ? "speaker.wave.1" : "speaker.slash").foregroundStyle(.secondary).frame(width: 18)
                    Slider(value: Binding(get: { level }, set: { model.setVolume($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
                }
                .help(L10n.t("Volume of this Mac's sound on the iMac; the iMac's own volume applies on top",
                             "iMac에서 재생하는 이 Mac 소리의 음량. iMac 자체 음량도 함께 적용됩니다"))
                HStack {
                    if let buffer = s.receiver?.audioBufferMs {
                        Text(L10n.t("Sent to the iMac · \(Int(buffer)) ms buffered", "iMac으로 보내는 중 · 버퍼 \(Int(buffer))ms"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // A denied permission still yields a tap, of silence
                    Button(L10n.t("No sound?", "소리가 안 나나요?")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help(L10n.t("Opens Privacy → System Audio Recording: Afterscreen needs it on",
                                 "개인정보 보호 → 시스템 오디오 녹음을 엽니다. Afterscreen를 켜 두어야 합니다"))
                }
            }
        }
    }
}

/// Automatic, then each link that reaches the receiver now
private struct LinkPicker: View {
    @ObservedObject var model: AppModel
    var receiver: String

    var body: some View {
        Picker(L10n.t("Link", "연결"), selection: Binding(get: { model.settings.link }, set: { model.setLink($0) })) {
            Text(L10n.t("Automatic", "자동")).tag(LinkKind?.none)
            ForEach(LinkMenu.choices(available: model.links[receiver] ?? [], pinned: model.settings.link), id: \.kind) { choice in
                Text("\(LinkLabel.glyph(choice.kind)) \(LinkLabel.name(choice.kind))"
                     + (choice.reachable ? "" : L10n.t(" (not reachable now)", " (지금 연결 안 됨)")))
                    .tag(LinkKind?.some(choice.kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help(L10n.t("Automatic uses the fastest link that reaches the receiver", "자동은 수신기에 닿는 가장 빠른 링크를 씁니다"))
    }
}

/// Quality test result: verdict, link and one bar per stage
private struct QualityCard: View {
    var report: QualityTest.Report
    var testing: Bool

    var body: some View {
        Card(title: L10n.t("Quality test · \(report.receiver)", "품질 테스트 · \(report.receiver)")) {
            if let v = report.verdict {
                Text("\(QualityTest.label(v.size)) · \(Int(v.fps.rounded())) fps").font(.system(size: 24, weight: .bold, design: .rounded))
            } else if !testing && !report.stages.isEmpty {
                Text(L10n.t("Under \(Int(QualityTest.smoothFPS)) fps at every size", "모든 크기에서 \(Int(QualityTest.smoothFPS))fps 미만"))
                    .font(.system(size: 15, weight: .semibold))
            }
            if report.link != nil {
                Text("\(LinkLabel.glyph(report.link)) \(LinkLabel.name(report.link)) · \(report.path)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(report.stages.indices, id: \.self) { i in stageRow(report.stages[i]) }
            if testing {
                HStack {
                    ProgressView(value: Double(report.stages.count), total: Double(max(1, report.total)))
                    Text(report.running.map { L10n.t("Testing \(QualityTest.label($0))…", "\(QualityTest.label($0)) 측정 중…") }
                         ?? L10n.t("Measuring the link…", "링크 측정 중…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stageRow(_ stage: QualityTest.Stage) -> some View {
        let color: Color = stage.fps >= QualityTest.smoothFPS ? .green : (stage.fps >= 30 ? .yellow : .red)
        return HStack(spacing: 8) {
            Text(QualityTest.label(stage.size)).frame(width: 42, alignment: .leading)
            Text("\(stage.size.width)×\(stage.size.height)").foregroundStyle(.secondary)
            Spacer()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 60, height: 6)
                Capsule().fill(color).frame(width: 60 * min(1, stage.fps / 60), height: 6)
            }
            Text("\(Int(stage.fps.rounded())) fps").frame(width: 48, alignment: .trailing)
            Text(String(format: "%.1f Gb/s", stage.gbps)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

public struct PopoverView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    @State private var showHardware = false

    public init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isTesting {
                testBody
            } else if model.isActive || model.snapshot.isStreaming {
                streamingBody
            } else {
                idleBody
            }
            Divider()
            HStack {
                if let message = model.lastMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L10n.t("Settings…", "설정…"), action: openSettings).keyboardShortcut(",")
                Button(L10n.t("Quit", "종료")) { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Afterscreen").font(.headline)
            if !model.screenRecordingGranted {
                HStack {
                    Text(L10n.t("Screen Recording permission is required", "화면 기록 권한이 필요합니다"))
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.t("Open Settings", "설정 열기")) { model.openPrivacySettings() }
                }
            }
            SoundCard(model: model)
            if let report = model.testReport { QualityCard(report: report, testing: false) }
            Card(title: L10n.t("Receivers", "수신기")) {
                if model.receivers.isEmpty {
                    Text(L10n.t("Looking for Afterscreen Receiver… Start it on the iMac, then connect a Thunderbolt, USB or Ethernet cable, or join the same network.",
                                "Afterscreen Receiver를 찾는 중… iMac에서 실행한 뒤 Thunderbolt, USB, 이더넷 케이블을 연결하거나 같은 네트워크에 연결하세요."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.receivers) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name).font(.system(size: 13, weight: .medium))
                            Text([r.model, r.panel].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinkPicker(model: model, receiver: r.name)
                        Button(L10n.t("Test", "테스트")) { model.runQualityTest(r) }
                            .help(L10n.t("Measure the highest resolution and frame rate this receiver and link sustain",
                                         "이 수신기와 링크로 낼 수 있는 최대 해상도와 프레임을 측정합니다"))
                        Button(L10n.t("Connect", "연결")) { model.connect(r) }
                    }
                }
            }
        }
    }

    private var testBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Quality test", "품질 테스트")).font(.headline)
            Text(L10n.t("The iMac shows full-motion frames at each size for a few seconds.",
                        "iMac에 크기별로 몇 초씩 전체가 움직이는 화면이 나옵니다."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let report = model.testReport { QualityCard(report: report, testing: true) }
            HStack {
                Spacer()
                Button(L10n.t("Stop", "중지")) { model.stopTest() }
            }
        }
    }

    private var streamingBody: some View {
        let s = model.snapshot
        let scoreColor: Color
        switch ScoreBand(s.cableScore) {
        case .good: scoreColor = .green
        case .fair: scoreColor = .yellow
        case .poor: scoreColor = .red
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.peer?.marketingName ?? model.activeReceiver ?? L10n.t("Receiver", "수신기")).font(.headline)
                Spacer()
                Text(s.isStreaming ? "● " + L10n.t("Streaming", "스트리밍 중") : s.state).font(.system(size: 11))
                    .foregroundStyle(s.isStreaming ? .green : .secondary)
            }
            SoundCard(model: model)
            if let level = model.brightness {
                Card(title: L10n.t("iMac brightness", "iMac 밝기")) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { level }, set: { model.setBrightness($0) }), in: 0...1)
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                }
            }
            Card(title: L10n.t("Connection", "연결")) {
                Row(label: L10n.t("Link", "링크"), value: "\(LinkLabel.glyph(s.link)) \(LinkLabel.name(s.link)) · \(s.interface ?? "—")",
                    help: L10n.t("The link carrying the stream, and the local interface", "스트림이 지나는 링크와 이 Mac의 인터페이스")) {
                    if let receiver = model.activeReceiver { LinkPicker(model: model, receiver: receiver) }
                }
                if let missing = s.missingLink {
                    Text(L10n.t("\(LinkLabel.name(missing)) does not reach the receiver; using the fastest link",
                                "\(LinkLabel.name(missing))(으)로는 수신기에 닿지 않아 가장 빠른 링크를 씁니다"))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let advice = LinkMetrics.usbFallbackAdvice(link: s.link) {
                    Text(advice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Row(label: L10n.t("Throughput", "전송량"), value: Format.gbps(bytesPerSecond: s.throughputBitsPerSecond / 8),
                    help: L10n.t("Data sent to the iMac per second; it rises as more of the screen changes",
                                 "지금 iMac으로 보내는 초당 데이터 양입니다. 화면이 많이 바뀔수록 커집니다")) {
                    Sparkline(values: s.throughputHistory, color: .green)
                }
                Row(L10n.t("Measured link speed", "링크 실측 속도"), s.capacityGbps.map { String(format: "%.2f Gbps", $0) } ?? "—",
                    help: L10n.t("Data actually sent over this link in 0.3 s when the session started; not the cable's rated speed",
                                 "연결할 때 0.3초 동안 실제로 보내 본 속도입니다. 케이블 규격 속도(예: Thunderbolt 40Gbps)가 아닙니다"))
                Row(label: L10n.t("Latency", "지연"), value: s.latencyMs.map(Format.ms) ?? "—",
                    help: L10n.t("Round trip to the iMac and back over this link", "이 링크로 iMac까지 왕복하는 시간")) {
                    Sparkline(values: s.latencyHistory, color: .blue)
                }
                Row(L10n.t("Jitter", "지연 변동"), Format.ms(s.jitterMs),
                    help: L10n.t("How much the latency varies", "지연 시간이 흔들리는 정도"))
                Row(L10n.t("Retransmits", "재전송"), String(format: "%.2f%%", s.retransmitPercent),
                    help: L10n.t("Packets sent again after a loss; high values point at the cable or Wi-Fi",
                                 "손실로 다시 보낸 패킷 비율. 높으면 케이블이나 Wi-Fi 상태를 의심하세요"))
                Row(L10n.t("Link quality", "링크 품질"), s.cableScore.map { "\($0) / 100" } ?? "—", color: scoreColor,
                    help: L10n.t("100 minus penalties for retransmits, jitter and a capacity below what the stream needs",
                                 "100점에서 재전송, 지연 변동, 부족한 링크 속도만큼 깎은 점수"))
                if let mtu = s.mtu {
                    let advice = LinkLabel.mtuAdvice(mtu: mtu, link: s.link)
                    Row("MTU", advice.map { "\(mtu) · \($0)" } ?? "\(mtu)", color: advice == nil ? .primary : .orange,
                        help: L10n.t("Packet size; 9000 (jumbo frames) lowers CPU on Thunderbolt and USB",
                                     "패킷 크기. Thunderbolt·USB에서는 9000(점보 프레임)이 CPU를 덜 씁니다"))
                }
            }
            Card(title: L10n.t("Picture", "화면")) {
                Row(L10n.t("Frames: captured · sent · shown", "프레임: 캡처 · 전송 · 표시"),
                    "\(Int(s.captureFPS.rounded())) · \(Int(s.sentFPS.rounded())) · \(Int((s.receiver?.displayedFPS ?? 0).rounded()))",
                    help: L10n.t("Per second: frames the Mac drew, sent, and the iMac showed", "초당 Mac이 그린 프레임, 보낸 프레임, iMac이 표시한 프레임"))
                Row(L10n.t("Dropped / min", "버린 프레임/분"), "\(s.droppedPerMinute)",
                    help: L10n.t("Frames replaced by a newer one before they could be sent", "보내기 전에 더 새 프레임으로 대체된 수"))
                if let c = s.config {
                    Row(L10n.t("Resolution", "해상도"), "\(c.streamPixels.width)×\(c.streamPixels.height)",
                        help: L10n.t("Still areas are sent losslessly at this size", "멈춘 영역은 이 해상도로 무손실 전송합니다"))
                    if let motion = MotionLabel.text(path: c.path, lossyTiles: s.lossyTiles) {
                        Row(L10n.t("Moving areas", "움직이는 영역"), motion,
                            help: L10n.t("BC7 while half the measured link covers it; past that, BC1 at half the size, which bands gradients",
                                         "링크 실측 속도의 절반 안에서는 BC7로 선명하게, 넘으면 절반 크기인 BC1로 보냅니다. BC1은 그라데이션에 띠가 생깁니다"))
                    }
                    if let v = c.video {
                        Row(L10n.t("Moving areas", "움직이는 영역"),
                            MotionLabel.video(v),
                            help: L10n.t("On slower links, areas in motion go out as video", "느린 링크에서는 움직이는 영역을 비디오로 보냅니다"))
                    }
                    Row(L10n.t("Changed area", "바뀐 영역"), String(format: "%.0f%%", s.dirtyPercent),
                        help: L10n.t("Share of the screen sent again in the last second", "최근 1초 동안 다시 보낸 화면 비율"))
                    Row(L10n.t("Compression", "압축률"), s.compressionRatio > 0 ? String(format: "%.1f×", s.compressionRatio) : "—",
                        help: L10n.t("Picture data before and after compression; 1.0× when the link carries it uncompressed",
                                     "압축 전후 데이터 비율. 링크에 여유가 있으면 압축하지 않아 1.0×"))
                }
                Row(label: L10n.t("Smooth gradients", "계단 완화"), value: "",
                    help: L10n.t("Fills 8-bit steps in dark gradients on the iMac. Higher reaches wider and uses more iMac GPU",
                                 "어두운 그라데이션의 8비트 계단을 iMac에서 부드럽게 메웁니다. 강할수록 넓게 메우고 iMac GPU를 더 씁니다")) {
                    Picker("", selection: Binding(get: { model.settings.deband }, set: { model.setDeband($0) })) {
                        ForEach(Deband.allCases, id: \.self) { Text(DebandLabel.name($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Row(L10n.t("Encode time", "인코딩 시간"), Format.ms(s.encodeMs),
                    help: L10n.t("From capture to send, per frame", "프레임 하나를 캡처해서 보내기까지 걸린 시간"))
            }
            Card(title: L10n.t("Resources", "자원 사용")) {
                Row(L10n.t("This Mac: CPU · RAM · GPU", "이 Mac: CPU · 메모리 · GPU"),
                    "\(Format.percent(s.cpuPercent)) · \(Format.bytes(s.memoryBytes)) · \(Format.percent(s.gpuPercent))")
                if let r = s.receiver {
                    Row(L10n.t("iMac: CPU · RAM · GPU", "iMac: CPU · 메모리 · GPU"),
                        "\(Format.percent(r.cpuPercent)) · \(Format.bytes(r.memoryBytes)) · \(Format.percent(r.gpuPercent))")
                    Row(L10n.t("iMac upload · decompress", "iMac 업로드 · 압축 해제"), "\(Format.ms(r.uploadMs)) · \(Format.ms(r.decompressMs))")
                } else {
                    Row("iMac", L10n.t("waiting for stats", "통계 기다리는 중"))
                }
            }
            DisclosureGroup(isExpanded: $showHardware) {
                if let p = s.peer {
                    VStack(alignment: .leading, spacing: 3) {
                        Row(L10n.t("Model", "모델"), "\(p.marketingName) (\(p.modelID))")
                        Row(L10n.t("Panel", "패널"), "\(p.panelPixels.width)×\(p.panelPixels.height)")
                        Row("GPU", p.gpuNames.joined(separator: ", "))
                        Row("macOS", p.osVersion)
                        Row(L10n.t("Hardware decode", "하드웨어 디코딩"),
                            "BC7 · HEVC \(p.hevcDecode ? "✓" : "✗")\(p.hevcMain10Decode ? " 10-bit" : "") · H.264 \(p.h264Decode ? "✓" : "✗")")
                    }
                    .padding(.top, 4)
                }
            } label: {
                Text(L10n.t("iMac hardware", "iMac 하드웨어")).font(.system(size: 12, weight: .medium))
            }
            HStack {
                Spacer()
                Button(L10n.t("Disconnect", "연결 끊기")) { model.disconnect() }
            }
        }
    }
}
