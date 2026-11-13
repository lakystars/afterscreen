import AppKit
import Combine
import AfterscreenCore
import SwiftUI

/// Link menu: answering links, then an unreachable pinned link
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
    /// Four characters, left-padded with figure spaces
    /// Fixed width keeps the status item and popover in place
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

/// Menu bar item: link mark while streaming
/// Optional fps and throughput at a fixed width
enum StatusTitle {
    static func mark(_ s: SenderSnapshot) -> LinkKind? {
        s.isStreaming ? s.link : nil
    }

    static func text(_ s: SenderSnapshot, stats: Bool) -> String {
        guard s.isStreaming, stats else { return "" }
        let fps = String(Int(s.sentFPS.rounded()))
        return String(repeating: "\u{2007}", count: max(0, 2 - fps.count)) + fps + "fps · " + Format.compactGbps(s.throughputBitsPerSecond)
    }
}

/// The link's symbol before its name
struct LinkName: View {
    var kind: LinkKind?
    var suffix = ""

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = LinkLabel.symbol(kind) { Image(systemName: symbol) }
            Text(LinkLabel.name(kind) + suffix)
        }
    }
}

/// Last `window` samples, fixed step, newest at the trailing edge
/// Scaled to the visible peak; `closed` adds the area below
private struct SeriesShape: Shape {
    var values: [Double]
    /// One sample a second: 60 s across the box
    var window = 60
    /// Least full scale: small swings stay small
    var floor = 0.0
    var closed = false

    func path(in rect: CGRect) -> Path {
        Path { path in
            let shown = values.suffix(window)
            guard shown.count > 1, let peak = shown.max() else { return }
            let top = max(peak, floor)
            guard top > 0 else { return }
            let step = rect.width / CGFloat(window - 1)
            let start = rect.maxX - CGFloat(shown.count - 1) * step
            // Peak at 80% height: clear of the top edge
            let scale = rect.height * 0.8 / CGFloat(top)
            for (i, v) in shown.enumerated() {
                let point = CGPoint(x: start + CGFloat(i) * step, y: rect.maxY - CGFloat(v) * scale)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            if closed {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: start, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

/// One line of the rows' value font
private let textRowHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize)))

/// Controls in a row's value area
enum RowControls {
    /// Settings page: system size
    case regular
    /// Small pickers, mini switches; rows as tall as needed
    case small
    /// As `small`, hanging over text-height rows
    case overhanging
}

private struct RowControlsKey: EnvironmentKey {
    static let defaultValue = RowControls.regular
}

extension EnvironmentValues {
    var rowControls: RowControls {
        get { self[RowControlsKey.self] }
        set { self[RowControlsKey.self] = newValue }
    }
}

/// Sections over a pinned bottom part, within `height`
/// Sections get their own height or what the bottom leaves
/// A max-height frame leaves an unproposed height unclamped
private struct PopoverColumn: Layout {
    var height: CGFloat
    var spacing: CGFloat

    private func heights(width: CGFloat?, room: CGFloat, _ subviews: Subviews) -> (top: CGFloat, gap: CGFloat, bottom: CGFloat) {
        let proposal = ProposedViewSize(width: width, height: nil)
        let top = subviews.first?.sizeThatFits(proposal).height ?? 0
        guard subviews.count > 1 else { return (min(top, room), 0, 0) }
        let bottom = subviews[1].sizeThatFits(proposal).height
        return (min(top, max(0, room - bottom - spacing)), spacing, bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let h = heights(width: proposal.width, room: height, subviews)
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: h.top + h.gap + h.bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let h = heights(width: bounds.width, room: height, subviews)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: h.top))
        guard subviews.count > 1 else { return }
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h.top + h.gap),
                          proposal: ProposedViewSize(width: bounds.width, height: h.bottom))
    }
}

/// Label, value, optional trailing view; `help` shows on hover
private struct Row<Trailing: View>: View {
    var label: String
    var value: String
    /// SF Symbol drawn before the value
    var symbol: String?
    /// Monospaced for numbers; names read better proportional
    var mono = true
    var help: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.rowControls) private var controls

    var body: some View {
        // Label shrinks, never wraps; long values wrap
        // Wrapped values align trailing; label on the first line
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.middle)
            Spacer(minLength: 0)
            if let symbol = symbol { Image(systemName: symbol).foregroundStyle(.primary) }
            Text(value).font(.system(.body, design: mono ? .monospaced : .default)).foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
            trailing().controlSize(controls == .regular ? .regular : .small)
                .frame(height: controls == .overhanging ? textRowHeight : nil)
        }
        .font(.system(size: 12))
        .help(help ?? "")
    }
}

private extension Row where Trailing == EmptyView {
    init(_ label: String, _ value: String, mono: Bool = true, help: String? = nil) {
        self.init(label: label, value: value, mono: mono, help: help) { EmptyView() }
    }
}

/// Titled group on a tinted background to separate sections
/// `expanded`: the title folds it; the content picks its rows
private struct Card<Content: View>: View {
    var title: String
    var expanded: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: title, expanded: expanded)
            Box(content: content)
        }
    }
}

/// Tinted rounded background holding a section's rows
private struct Box<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

/// Section title; with `expanded`, the whole row folds it
/// Chevron at the trailing edge
private struct SectionTitle: View {
    var title: String
    var expanded: Binding<Bool>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let expanded = expanded {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    text
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded.wrappedValue ? L10n.t("Expanded", "펼침") : L10n.t("Collapsed", "접힘"))
        } else {
            text
        }
    }

    private var text: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Throughput and latency filling the box, each own scale
/// Overlay: link and values top trailing, score leading
private struct LinkChart<Picker: View>: View {
    var s: SenderSnapshot
    var receiver: String
    var scoreColor: Color
    @ViewBuilder var picker: () -> Picker

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        ZStack {
            // Floors: 10 Mbps, and 5 ms over whole-ms kernel RTT
            SeriesShape(values: s.throughputHistory, floor: 10e6, closed: true).fill(Color.green.opacity(0.12))
            SeriesShape(values: s.throughputHistory, floor: 10e6).stroke(Color.green.opacity(0.5), lineWidth: 1.2)
            SeriesShape(values: s.latencyHistory, floor: 5).stroke(Color.blue.opacity(0.5), lineWidth: 1.2)
            HStack(alignment: .center) {
                VStack(spacing: 0) {
                    Text(s.cableScore.map(String.init) ?? StatValue.dash)
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(scoreColor)
                    Text(StatName.quality).font(.system(size: 10)).foregroundStyle(.primary)
                }
                .help(L10n.t("100 minus penalties for retransmits, jitter and a capacity below what the stream needs",
                             "100점에서 재전송, 지연 변동, 부족한 링크 속도만큼 깎은 점수"))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        LinkName(kind: s.link).font(.system(size: 12)).lineLimit(1)
                        picker()
                    }
                    .help(L10n.t("The link carrying the stream", "스트림이 지나는 링크"))
                    value(StatName.throughput, Format.gbps(bytesPerSecond: s.throughputBitsPerSecond / 8), .green)
                        .help(L10n.t("Screen data sent to \(receiver) per second, without sound and cursor; it rises as more of the screen changes",
                                     "지금 \(receiver)에 보내는 초당 화면 데이터입니다. 소리와 커서는 빠집니다. 화면이 많이 바뀔수록 커집니다"))
                    value(StatName.latency, StatValue.latency(s.latencyMs), .blue)
                        .help(L10n.t("Round trip to \(receiver) and back over this link", "이 링크로 \(receiver)까지 왕복하는 시간"))
                    value(StatName.blocks, s.config.map { StatValue.blocks(percent: s.dirtyPercent, in: $0.streamPixels) } ?? StatValue.dash, .primary)
                        .help(L10n.t("64-pixel blocks that changed per frame, last second's average, of all on screen; video areas included. A still-looking screen with blocks here has something moving, like a spinner",
                                     "프레임마다 바뀐 64픽셀 블록 수의 최근 1초 평균과 전체 블록 수입니다. 비디오로 보낸 영역도 들어갑니다. 멈춘 것 같은 화면에서도 숫자가 있으면 스피너처럼 움직이는 곳이 있습니다"))
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(8)
        }
        .frame(height: 92)
        .background(shape.fill(Color.primary.opacity(0.06)))
        .clipShape(shape)
    }

    /// Value tinted like its series: the color is the legend
    private func value(_ name: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.system(size: 10)).foregroundStyle(.primary)
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(color)
        }
    }
}

/// Popover's second level: display, pairings, connection, menu bar, language
/// Explanations live in help tags: the popover stays short
private struct SettingsPage: View {
    @ObservedObject var feed: PopoverFeed
    @ObservedObject var settings: SenderSettings
    var back: () -> Void
    /// Re-read after a removal; the keychain posts no change
    @State private var paired: [(id: String, name: String)] = []
    private var model: AppModel { feed.model }

    init(feed: PopoverFeed, back: @escaping () -> Void) {
        self.feed = feed
        settings = feed.model.settings
        self.back = back
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Text(L10n.t("Settings", "설정")).font(.headline)
                HStack {
                    Button(action: back) { Label(L10n.t("Back", "뒤로"), systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("[", modifiers: .command)
                    Spacer()
                }
            }
            display
            pairings
            Card(title: L10n.t("Connection", "연결")) {
                VStack(alignment: .leading, spacing: 8) {
                    SwitchRow(title: L10n.t("Connect automatically", "자동으로 연결"), isOn: $settings.autoConnect)
                        .help(settings.lastReceiver.map {
                            L10n.t("Connects to \($0) when it appears, after sleep, and after the link drops",
                                   "\($0)에 다시 연결합니다: 보일 때, 잠자기에서 깨어났을 때, 링크가 끊겼을 때")
                        } ?? L10n.t("Connects to the receiver you last connected to", "마지막으로 연결한 수신기에 연결합니다"))
                    SwitchRow(title: L10n.t("Open at login", "로그인 시 열기"),
                              isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    Row(label: L10n.t("Receiver power after disconnecting", "연결 끊은 뒤 수신기 전원"), value: "", help: ReceiverPower.help(mac: model.macName)) {
                        Picker("", selection: $settings.endPower) {
                            ForEach(ReceiverPower.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            if model.snapshot.isStreaming, let options = model.snapshot.receiverOptions, options.editable {
                ReceiverOptionsCard(options: options, receiver: model.receiverName) { model.changeReceiver($0) }
            }
            Card(title: L10n.s("Menu bar")) {
                SwitchRow(title: L10n.s("Show frame rate and throughput"), isOn: $settings.menuBarStats)
                    .help(L10n.s("Off: the icon only"))
            }
            Card(title: L10n.s("Updates")) {
                SwitchRow(title: L10n.s("Check for new versions"), isOn: $settings.checksUpdates)
                    .help(L10n.s("Asks GitHub for the latest release every 6 hours. GitHub sees this Mac's IP address"))
            }
            Card(title: L10n.t("Language", "언어")) {
                Picker(L10n.t("Language", "언어"), selection: $settings.language) {
                    ForEach(Language.allCases, id: \.self) { Text(L10n.name($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear { paired = model.pairedReceivers }
    }

    private var display: some View {
        let mac = model.macName, receiver = model.receiverName
        // Mirroring for this Mac keeps its own size
        let fixedSize = settings.displayRole == .mirror && settings.mirrorFit == .mac
        return Card(title: L10n.t("Display", "디스플레이")) {
            RoleRows(settings: settings, mac: mac, receiver: receiver)
            Row(label: L10n.t("Size", "크기"), value: "",
                help: fixedSize ? L10n.t("Mirroring for \(mac) shows its main display at its own size", "\(mac)에 맞춘 복제는 주 디스플레이를 그 크기 그대로 보여 줍니다")
                                : L10n.t("Applies while streaming. System Settings → Displays lists the same sizes", "스트리밍 중에도 바로 적용됩니다. 시스템 설정 → 디스플레이에도 같은 크기가 있습니다")) {
                Picker("", selection: $settings.displaySize) {
                    ForEach(DisplaySize.allCases) { size in
                        // Verbatim: no thousands separators
                        // No receiver seen yet: titles alone
                        Text(verbatim: model.panelPoints.map { base in
                            let p = size.points(for: base)
                            return "\(size.title) · \(p.width) × \(p.height)"
                        } ?? size.title).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(fixedSize)
            }
            Row(label: L10n.t("Transfer resolution", "전송 해상도"), value: "",
                help: L10n.t("Automatic: the panel's resolution when the measured link is fast enough, four fifths otherwise (5K iMac: 5120 × 2880 from about 0.5 Gbps, else 4096 × 2304). At four fifths the desktop switches to half that size, the sharpest there (5K iMac: looks like 2048 × 1152); at the panel's resolution it returns to the size above",
                             "자동: 측정한 링크가 충분히 빠르면 패널 해상도, 아니면 4/5 해상도로 보냅니다(5K iMac: 약 0.5 Gbps 이상이면 5120 × 2880, 아니면 4096 × 2304). 4/5 해상도일 때는 화면 크기를 그 절반으로 바꿔 가장 선명하게 보여 줍니다(5K iMac: 2048 × 1152처럼 보임). 패널 해상도로 보낼 때는 위에서 고른 크기로 돌아옵니다")) {
                Picker("", selection: $settings.streamResolution) {
                    ForEach(StreamResolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            SwitchRow(title: L10n.t("120 fps (experimental)", "120fps (실험)"), isOn: $settings.highRefresh)
                .help(L10n.t("For receivers at 120 Hz or more over Thunderbolt: \(mac)'s encoder is timed when connecting, and the stream goes at 120 fps when it takes under half a frame. Off: up to 60 fps. Applies from the next connection",
                             "120Hz 이상인 수신 화면에 Thunderbolt로 연결할 때, 연결하면서 \(mac)의 인코딩 시간을 재서 한 프레임의 절반 안에 끝나면 120fps로 보냅니다. 끄면 최대 60fps입니다. 다음 연결부터 적용됩니다"))
            Button(L10n.t("Arrange Displays…", "디스플레이 배치…")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private var pairings: some View {
        Card(title: L10n.s("Paired receivers")) {
            if paired.isEmpty {
                Text(L10n.s("None yet. Over Ethernet or Wi-Fi a receiver asks once for a code shown on its screen; Thunderbolt and USB cables need none."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(paired, id: \.id) { pair in
                HStack {
                    Text(pair.name).font(.system(size: 12))
                    Spacer()
                    Button(L10n.s("Remove")) {
                        model.removePairing(pair.id)
                        paired = model.pairedReceivers
                    }
                }
            }
        }
    }
}

/// The connected receiver's own settings, as it allows
/// Who may connect stays on the receiver
private struct ReceiverOptionsCard: View {
    var options: ReceiverOptions
    var receiver: String
    var edit: (ReceiverOptionsChange) -> Void

    private var reconnects: String { L10n.s("Applies by reconnecting at once") }

    var body: some View {
        Card(title: L10n.s("%@ settings", receiver)) {
            VStack(alignment: .leading, spacing: 8) {
                Row(label: L10n.t("Show the stream", "스트림 표시 방식"), value: "", help: reconnects) {
                    menu(Binding(get: { options.presentation }, set: { edit(ReceiverOptionsChange(presentation: $0)) })) {
                        ForEach(ReceiverOptions.Presentation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Row(label: L10n.t("Show on", "표시할 화면"), value: "",
                    help: L10n.s("Automatic: %@'s own panel first. %@", receiver, reconnects)) {
                    menu(Binding(get: { options.screen ?? "" }, set: { edit(ReceiverOptionsChange(screen: $0)) })) {
                        Text(L10n.t("Automatic", "자동")).tag("")
                        ForEach(options.screens, id: \.key) { screen in
                            // Verbatim: no thousands separators
                            Text(verbatim: "\(screen.name) · \(screen.pixels.width)×\(screen.pixels.height)").tag(screen.key)
                        }
                        if let missing = options.missingScreen, let key = options.screen {
                            Text(L10n.s("%@ (not connected)", missing)).tag(key)
                        }
                    }
                }
                SwitchRow(title: L10n.t("Switch to the panel's 1:1 resolution", "패널 1:1 해상도로 전환"),
                          isOn: Binding(get: { options.matchPanelMode }, set: { edit(ReceiverOptionsChange(matchPanelMode: $0)) }))
                    .help(L10n.t("While streaming, a scaled resolution on \(receiver) switches to the panel's own, so the stream is not resampled twice. \(reconnects)",
                                 "스트리밍하는 동안 \(receiver)의 스케일된 해상도를 패널 본래 해상도로 바꿔 스트림이 두 번 리샘플링되지 않게 합니다. \(reconnects)"))
                Row(label: L10n.t("Connection effect", "연결 효과"), value: "",
                    help: L10n.t("Applies from the next connection", "다음 연결부터 적용됩니다")) {
                    menu(Binding(get: { options.effect }, set: { edit(ReceiverOptionsChange(effect: $0)) })) {
                        ForEach(ReceiverOptions.Effect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Row(label: L10n.t("Display with no sender", "송신기가 없을 때 화면"), value: "",
                    help: L10n.t("After a disconnect. A stop on \(receiver) always shows its desktop", "연결이 끊긴 뒤의 화면입니다. \(receiver)에서 중지하면 항상 데스크톱이 보입니다")) {
                    menu(Binding(get: { options.onDisconnect }, set: { edit(ReceiverOptionsChange(onDisconnect: $0)) })) {
                        ForEach(ReceiverOptions.OnDisconnect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                SwitchRow(title: L10n.t("Open at login", "로그인 시 열기"),
                          isOn: Binding(get: { options.launchAtLogin }, set: { edit(ReceiverOptionsChange(launchAtLogin: $0)) }))
                Text(L10n.t("Connections it accepts, pairings and permission to shut down are set on \(receiver).",
                            "받을 연결, 페어링, 시스템 종료 허용은 \(receiver)에서 설정합니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func menu<Value: Hashable, Items: View>(_ selection: Binding<Value>, @ViewBuilder _ items: () -> Items) -> some View {
        Picker("", selection: selection, content: items)
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}

extension ReceiverOptions.Presentation {
    var title: String {
        switch self {
        case .space: return L10n.t("A desktop of its own", "별도 데스크톱")
        case .cover: return L10n.t("Cover the whole screen", "화면 전체 덮기")
        }
    }
}

extension ReceiverOptions.Effect {
    var title: String {
        switch self {
        case .tiles: return L10n.t("Tile wave", "타일 웨이브")
        case .none: return L10n.t("None", "없음")
        }
    }
}

extension ReceiverOptions.OnDisconnect {
    var title: String {
        switch self {
        case .showDesktop: return L10n.t("Show its desktop", "데스크톱 보기")
        case .sleepDisplay: return L10n.t("Turn the display off", "화면 끄기")
        }
    }
}

/// Receiver panel: follows this Mac, or its own slider
/// Following: this Mac's, then the receiver's offset
/// Not following: this Mac's, then the receiver's
private struct BrightnessCard: View {
    @ObservedObject var feed: PopoverFeed
    @ObservedObject var settings: SenderSettings
    private var model: AppModel { feed.model }

    init(feed: PopoverFeed) {
        self.feed = feed
        settings = feed.model.settings
    }

    var body: some View {
        let receiver = model.receiverName, mac = model.macName
        Card(title: L10n.t("Brightness", "밝기")) {
            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: L10n.t("Follow \(mac)'s brightness", "\(mac) 밝기 따라가기"),
                          isOn: Binding(get: { settings.brightnessFollows }, set: { model.setBrightnessFollows($0) }))
                    .help(L10n.t("On: \(receiver) follows \(mac)'s brightness keys, Control Center and auto-brightness. Off: set \(receiver) on its own, and dim \(mac) freely. \(receiver) stays as it is after you disconnect",
                                 "켜면 \(receiver) 밝기가 \(mac)의 밝기 키, 제어 센터, 자동 밝기를 따릅니다. 끄면 \(receiver) 밝기를 따로 정하고 \(mac) 화면은 마음대로 어둡게 둘 수 있습니다. 연결을 끊어도 \(receiver) 밝기는 그대로 둡니다"))
                if let level = model.snapshot.macBrightness {
                    LevelSlider(name: mac, value: level) { model.setMacBrightness($0) }
                    if settings.brightnessFollows, let id = model.snapshot.peer?.receiverID {
                        let stops = settings.brightnessOffset(for: id)
                        LevelSlider(name: L10n.t("\(receiver) brightness offset", "\(receiver) 밝기 보정"), value: stops,
                                    range: BrightnessOffset.range, detail: BrightnessOffset.label(stops)) {
                            settings.setBrightnessOffset($0, for: id)
                        }
                        .help(L10n.t("Keeps \(receiver) brighter or dimmer than \(mac) while following. At 0% both screens give the same nits. Once \(receiver) reaches its maximum, it gets no brighter",
                                     "따라가는 동안 \(receiver) 밝기를 \(mac)보다 밝거나 어둡게 맞춥니다. 0%면 두 화면의 니트가 같습니다. \(receiver) 밝기가 최대에 닿으면 더 밝아지지 않습니다"))
                    }
                } else if settings.brightnessFollows {
                    Text(L10n.t("\(mac) has no built-in screen on; \(receiver) keeps its brightness", "\(mac)에 켜진 내장 화면이 없어 \(receiver) 밝기를 그대로 둡니다"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !settings.brightnessFollows {
                    LevelSlider(name: receiver, value: settings.receiverBrightness) {
                        settings.receiverBrightness = $0
                    }
                }
            }
        }
    }
}

/// A name over its slider, boxed
/// Holds the dragged value until the stored one catches up
private struct LevelSlider: View {
    var name: String
    var value: Double
    var low = "sun.min"
    var high = "sun.max"
    var range: ClosedRange<Double> = 0...1
    /// Value text at the trailing edge
    var detail: String?
    var set: (Double) -> Void
    @State private var held: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if let detail = detail {
                    Spacer()
                    Text(detail).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                // Fixed width: tracks line up across cards
                Image(systemName: low).foregroundStyle(.secondary).frame(width: 18)
                let slider = Slider(value: Binding(get: { held ?? value }, set: { held = $0; set($0) }), in: range) { editing in
                    // Levels poll every 0.2 s; the offset snaps
                    if !editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { held = nil } }
                }
                .accessibilityLabel(name)
                if let detail = detail { slider.accessibilityValue(detail) } else { slider }
                Image(systemName: high).foregroundStyle(.secondary).frame(width: 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

/// Label at the leading edge, switch at the trailing
private struct SwitchRow: View {
    var title: String
    @Binding var isOn: Bool
    @Environment(\.rowControls) private var controls

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .controlSize(controls == .regular ? .regular : .mini)
                .frame(height: controls == .overhanging ? textRowHeight : nil)
        }
    }
}

/// Sound: play on the receiver, and this Mac's volume
/// Session only: idle has no receiver to play on
private struct SoundCard: View {
    @ObservedObject var feed: PopoverFeed
    @ObservedObject var settings: SenderSettings
    private var model: AppModel { feed.model }

    init(feed: PopoverFeed) {
        self.feed = feed
        settings = feed.model.settings
    }

    var body: some View {
        let receiver = model.receiverName, mac = model.macName
        Card(title: L10n.t("Sound", "소리")) {
            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: L10n.t("Play on \(receiver)", "\(receiver)에서 재생"), isOn: $settings.sound)
                    .help(L10n.t("\(mac) stays silent while \(receiver) plays; \(receiver) follows \(mac)'s volume and mute. Headphones and Bluetooth outputs like AirPods keep the sound. Asks once for System Audio Recording permission. About 1.5 Mbps",
                                 "\(receiver)에서 재생하는 동안 \(mac)에서는 소리가 나지 않고, \(receiver) 음량과 음소거는 \(mac) 설정을 따릅니다. 헤드폰이나 AirPods 같은 블루투스 출력으로 들을 때는 넘기지 않습니다. 처음 한 번 시스템 오디오 녹음 권한을 묻습니다. 약 1.5Mbps를 씁니다"))
                if settings.sound && model.snapshot.soundOnHeadphones {
                    Text(L10n.t("Headphones in use: sound stays on \(mac)", "헤드폰 사용 중이라 \(mac)에서 소리가 납니다"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // This Mac's output; named for where the sound comes out
                if let level = model.macVolume {
                    LevelSlider(name: settings.sound && model.snapshot.soundOnReceiver ? receiver : mac, value: level.volume,
                                low: level.muted ? "speaker.slash.fill" : "speaker.fill", high: "speaker.wave.3.fill") { model.setMacVolume($0) }
                }
            }
        }
    }
}

/// The code the receiver shows, typed here once per receiver
/// Networks only; point-to-point cables never ask
private struct PairingCard: View {
    @ObservedObject var feed: PopoverFeed
    var receiver: String
    @State private var code = ""
    @State private var shakes = 0
    @State private var wrong = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: AppModel { feed.model }

    var body: some View {
        // Receiver named once, in the title
        Card(title: L10n.t("Pair with \(receiver)", "\(receiver) 페어링")) {
            Text(L10n.t("Type the 6-digit code shown on its screen.", "화면에 뜬 6자리 코드를 입력하세요."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CodeBoxes(code: $code, wrong: wrong, onSubmit: submit)
                .modifier(Shake(phase: CGFloat(shakes)))
                .padding(.vertical, 4)
            HStack {
                if model.wrongCodes > 0 && code.isEmpty {
                    Text(L10n.t("Wrong code; type it again", "코드가 맞지 않습니다. 다시 입력하세요"))
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button(L10n.t("Cancel", "취소")) { model.disconnect() }
                Button(L10n.t("Pair", "페어링"), action: submit).disabled(code.count != 6).keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: model.wrongCodes) { old, new in
            guard new > old else { return }
            wrong = true
            // Reduced motion: red boxes alone
            if !reduceMotion { withAnimation(.linear(duration: Shake.duration)) { shakes += 1 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Shake.duration) {
                code = ""
                wrong = false
            }
        }
    }

    private func submit() {
        guard code.count == 6 else { return }
        model.submitPairingCode(code)
    }
}

/// Six boxes drawn over one hidden field
/// Typing fills the next box; backspace clears the one before
/// One field: paste, IME, deletion work as text; no gaps
private struct CodeBoxes: View {
    private static let count = 6
    @Binding var code: String
    var wrong = false
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .onSubmit(onSubmit)
                .onChange(of: code) { _, typed in
                    // ASCII digits only, six at most
                    let digits = String(typed.filter { ("0"..."9").contains($0) }.prefix(Self.count))
                    if digits != typed { code = digits }
                }
                .opacity(0)
                .accessibilityLabel(L10n.t("Pairing code", "페어링 코드"))
            // 3 + 3, as the iMac shows the code
            HStack(spacing: 20) {
                ForEach([0..<3, 3..<6], id: \.lowerBound) { group in
                    HStack(spacing: 8) { ForEach(group, id: \.self) { box($0) } }
                }
            }
            // Clicks land on the boxes, never the hidden caret
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
    }

    /// Box the next digit goes in; the last once full
    private var next: Int { min(code.count, Self.count - 1) }

    private func box(_ i: Int) -> some View {
        let digit = i < code.count ? String(Array(code)[i]) : ""
        let current = focused && i == next
        return ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(wrong ? Color.red : current ? Color.accentColor : Color.primary.opacity(digit.isEmpty ? 0.15 : 0.3),
                              lineWidth: wrong || current ? 2 : 1)
            if current && digit.isEmpty {
                Caret()
            } else {
                Text(digit).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
    }
}

/// Wrong-code shake: three swings, fading out
/// One shake per unit of phase
private struct Shake: GeometryEffect {
    static let duration = 0.45
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = phase - phase.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 10 * sin(t * .pi * 6) * (1 - t), y: 0))
    }
}

/// Blinking insertion point
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 20)
                .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
        }
    }
}

/// Extend or mirror, and the mirror's fit
/// Redraws alone on a settings change
private struct RoleRows: View {
    @ObservedObject var settings: SenderSettings
    var mac: String
    var receiver: String
    @Environment(\.rowControls) private var controls

    var body: some View {
        Row(label: L10n.t("Use as", "사용 방식"), value: "", help: DisplayRole.help(mac: mac, receiver: receiver)) {
            Picker("", selection: $settings.displayRole) {
                ForEach(DisplayRole.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if settings.displayRole == .mirror {
            Row(label: L10n.t("Optimize for", "맞춤 대상"), value: "", help: MirrorFit.help(mac: mac, receiver: receiver)) {
                // Two Mac names outgrow a segmented control here
                Picker("", selection: $settings.mirrorFit) {
                    ForEach(MirrorFit.allCases) { Text($0.title(mac: mac, receiver: receiver)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            // Under another control: hanging over would touch it
            .environment(\.rowControls, controls == .overhanging ? .small : controls)
        }
    }
}

/// Automatic, then each link that reaches the receiver now
private struct LinkPicker: View {
    @ObservedObject var feed: PopoverFeed
    var receiver: String
    private var model: AppModel { feed.model }

    var body: some View {
        Picker(L10n.t("Link", "연결"), selection: Binding(get: { model.settings.link }, set: { model.setLink($0) })) {
            Text(L10n.t("Automatic", "자동")).tag(LinkKind?.none)
            ForEach(LinkMenu.choices(available: model.links[receiver] ?? [], pinned: model.settings.link), id: \.kind) { choice in
                // Names only: menus draw item symbols dimmer than their text
                Text(LinkLabel.name(choice.kind) + (choice.reachable ? "" : L10n.t(" (not reachable now)", " (지금 연결 안 됨)")))
                    .tag(LinkKind?.some(choice.kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help(L10n.t("Automatic uses the fastest link that reaches the receiver", "자동은 수신기에 닿는 가장 빠른 링크를 씁니다"))
    }
}

/// Quality test result: verdict, link, one bar per stage, typical use
private struct QualityCard: View {
    var report: QualityTest.Report
    var testing: Bool

    var body: some View {
        Card(title: L10n.t("Quality test · \(report.receiver)", "품질 테스트 · \(report.receiver)")) {
            if let v = report.verdict {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(QualityTest.label(v.size)) · \(Int(v.fps.rounded())) fps").font(.system(size: 24, weight: .bold, design: .rounded))
                    // Motion goes as a smaller video layer
                    if let m = v.motion, m != v.size {
                        Text(L10n.t("motion \(QualityTest.label(m))", "움직임 \(QualityTest.label(m))"))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            } else if !testing && !report.stages.isEmpty {
                Text(L10n.t("Under \(Int(QualityTest.smoothFPS(report.frameRate))) fps at every size",
                            "모든 크기에서 \(Int(QualityTest.smoothFPS(report.frameRate)))fps 미만"))
                    .font(.system(size: 15, weight: .semibold))
            }
            if report.link != nil {
                LinkName(kind: report.link, suffix: " · \(report.path)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(report.stages.indices, id: \.self) { i in stageRow(report.stages[i], label: QualityTest.label(report.stages[i].size)) }
            if let t = report.typical {
                stageRow(t, label: L10n.t("Typical", "실사용")).padding(.top, 4)
            }
            if testing {
                HStack {
                    ProgressView(value: Double(report.done), total: Double(max(1, report.total)))
                    Text(report.running.map { report.runningTypical ? L10n.t("Testing typical use…", "실사용 측정 중…")
                                                                    : L10n.t("Testing \(QualityTest.label($0))…", "\(QualityTest.label($0)) 측정 중…") }
                         ?? L10n.t("Measuring the link…", "링크 측정 중…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stageRow(_ stage: QualityTest.Stage, label: String) -> some View {
        let rate = report.frameRate
        let color: Color = stage.fps >= QualityTest.smoothFPS(rate) ? .green : (stage.fps >= rate / 2 ? .yellow : .red)
        return HStack(spacing: 8) {
            Text(label).frame(width: 52, alignment: .leading)
            Text(verbatim: "\(stage.size.width)×\(stage.size.height)").foregroundStyle(.secondary)
            Spacer()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 60, height: 6)
                Capsule().fill(color).frame(width: 60 * min(1, stage.fps / rate), height: 6)
            }
            Text("\(Int(stage.fps.rounded())) fps").frame(width: 48, alignment: .trailing)
            Text(String(format: "%.1f Gb/s", stage.gbps)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

/// Model changes reach the views only while shown
/// Closed, the graph would update on every stats tick
final class PopoverFeed: ObservableObject {
    let model: AppModel
    let objectWillChange = ObservableObjectPublisher()
    /// Set before showing, cleared once closed
    /// Opening renders once: changes while closed went unseen
    var isOpen = false {
        didSet { if isOpen { objectWillChange.send() } }
    }
    private var forward: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        forward = model.objectWillChange.sink { [weak self] _ in
            guard let self = self, self.isOpen else { return }
            self.objectWillChange.send()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var feed: PopoverFeed
    // Folded by default; kept across popover openings
    @AppStorage("popover.connection") private var showConnection = false
    @AppStorage("popover.picture") private var showPicture = false
    @AppStorage("popover.resources") private var showResources = false
    @AppStorage("popover.hardware") private var showHardware = false
    @State private var showOthers = false
    private var model: AppModel { feed.model }

    init(feed: PopoverFeed) {
        self.feed = feed
    }

    var body: some View {
        // Taller than the screen: sections scroll, buttons stay
        PopoverColumn(height: model.popoverHeight, spacing: 10) {
            ScrollView {
                Group {
                    if model.showsSettings {
                        SettingsPage(feed: feed) { model.showsSettings = false }
                    } else if model.isTesting {
                        testBody
                    } else if inSession {
                        // Stat rows share one pitch
                        streamingBody.environment(\.rowControls, .overhanging)
                    } else {
                        idleBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Inside: focus rings and the scroller stay clear
                .padding(.horizontal, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A new page starts at the top
            .id(model.showsSettings)
            if !model.showsSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    if let update = model.availableUpdate { updateRow(update) }
                    // Session action left, app actions right
                    if model.isTesting || inSession, let message = model.lastMessage { note(message) }
                    HStack {
                        if model.isTesting {
                            Button(L10n.t("Stop", "중지")) { model.stopTest() }
                        } else if inSession {
                            Button(L10n.t("Disconnect", "연결 끊기")) { model.disconnect(powerReceiver: true) }
                        } else if let message = model.lastMessage {
                            note(message)
                        }
                        Spacer()
                        Button(L10n.t("Settings", "설정")) { model.showsSettings = true }.keyboardShortcut(",")
                        Button(L10n.t("Quit", "종료")) { NSApp.terminate(nil) }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 380)
    }

    /// Connecting or streaming; a quality test excluded
    private var inSession: Bool { !model.isTesting && (model.isActive || model.snapshot.isStreaming) }

    private func updateRow(_ update: AvailableUpdate) -> some View {
        let receiver = model.receiverName, mac = model.macName
        let text = update.mac && update.receiver ? L10n.s("Version %@ is out for %@ and %@", update.version, mac, receiver)
            : update.receiver ? L10n.s("Version %@ is out for %@", update.version, receiver)
            : L10n.s("Version %@ is out", update.version)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            note(text)
            Spacer()
            Button(L10n.s("Download")) { NSWorkspace.shared.open(update.page) }.controlSize(.small)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
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
            if let report = model.testReport { QualityCard(report: report, testing: false) }
            Card(title: L10n.t("Receivers", "수신기")) {
                if model.receivers.isEmpty {
                    Text(L10n.t("Looking for Afterscreen Receiver… Start it on the Mac to use as a screen, then connect a Thunderbolt, USB or Ethernet cable, or join the same network.",
                                "Afterscreen Receiver를 찾는 중… 화면으로 쓸 Mac에서 실행한 뒤 Thunderbolt, USB, 이더넷 케이블을 연결하거나 같은 네트워크에 연결하세요."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let mine = model.receivers.filter(model.isPaired)
                let others = model.receivers.filter { !model.isPaired($0) }
                ForEach(mine) { receiverRow($0) }
                if mine.isEmpty {
                    ForEach(others) { receiverRow($0) }
                } else if !others.isEmpty {
                    DisclosureGroup(isExpanded: $showOthers) {
                        ForEach(others) { receiverRow($0) }
                    } label: {
                        Text(L10n.s("Other receivers (%lld)", others.count)).font(.system(size: 12))
                    }
                }
            }
        }
    }

    /// Paired receivers carry a lock: they connect without a code
    /// Controls on their own line: names stay whole
    private func receiverRow(_ r: DiscoveredReceiver) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(r.name).font(.system(size: 13, weight: .medium))
                    if model.isPaired(r) {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(L10n.t("Paired: connects over Ethernet and Wi-Fi without a code", "페어링됨: 이더넷·Wi-Fi에서도 코드 없이 연결합니다"))
                    }
                }
                Text([r.model, r.panel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                LinkPicker(feed: feed, receiver: r.name)
                Spacer()
                Button(L10n.t("Test", "테스트")) { model.runQualityTest(r) }
                    .help(L10n.t("Measure the highest resolution and frame rate, then typical use, on this receiver and link",
                                 "이 수신기와 링크로 낼 수 있는 최대 해상도와 프레임, 실사용 프레임을 측정합니다"))
                Button(L10n.t("Connect", "연결")) { model.connect(r) }
            }
        }
    }

    private var testBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Quality test", "품질 테스트")).font(.headline)
            if let name = model.pairingWith { PairingCard(feed: feed, receiver: name).id(model.pairingAttempt) }
            Text(L10n.t("\(model.testReport?.receiver ?? model.receiverName) shows full-motion frames at each size for a few seconds.",
                        "\(model.testReport?.receiver ?? model.receiverName)에 크기별로 몇 초씩 전체가 움직이는 화면이 나옵니다."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let report = model.testReport { QualityCard(report: report, testing: true) }
        }
    }

    private var streamingBody: some View {
        let s = model.snapshot
        let receiver = model.receiverName, mac = model.macName
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
            if let name = model.pairingWith { PairingCard(feed: feed, receiver: name).id(model.pairingAttempt) }
            SoundCard(feed: feed)
            if s.isStreaming { BrightnessCard(feed: feed) }
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: StatName.connection, expanded: $showConnection)
                LinkChart(s: s, receiver: receiver, scoreColor: scoreColor) {
                    if let receiver = model.activeReceiver { LinkPicker(feed: feed, receiver: receiver) }
                }
                // Warnings stay visible while folded
                if let missing = s.missingLink {
                    Text(L10n.t("\(LinkLabel.name(missing)) does not reach the receiver; using the fastest link",
                                "\(LinkLabel.name(missing))(으)로는 수신기에 닿지 않아 가장 빠른 링크를 씁니다"))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let advice = LinkMetrics.usbFallbackAdvice(link: s.link) {
                    Text(advice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if s.qualityLowered, let now = s.videoBitrate, let start = s.videoStartBitrate {
                    Text(L10n.t("The network is busy: sending at lower quality (video \(now / 1_000_000) of \(start / 1_000_000) Mbps)",
                                "네트워크가 혼잡해 화질을 낮춰 보내는 중입니다(영상 \(now / 1_000_000)/\(start / 1_000_000) Mbps)"))
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if showConnection {
                    Box {
                        Row(L10n.t("Interface", "인터페이스"), s.interface ?? StatValue.dash,
                            help: L10n.t("\(mac)'s network interface on that link", "그 링크에 쓰이는 \(mac)의 네트워크 인터페이스"))
                        Row(StatName.capacity, StatValue.capacity(s.capacityGbps),
                            help: L10n.t("Measured once at connect by sending data for 0.3 s; not the cable's rated speed",
                                         "연결할 때 한 번, 0.3초 동안 실제로 보내 본 속도입니다. 케이블 규격 속도(예: Thunderbolt 40Gbps)가 아닙니다"))
                        Row(StatName.jitter, StatValue.latency(s.jitterMs),
                            help: L10n.t("How much the latency varies", "지연 시간이 흔들리는 정도"))
                        Row(StatName.retransmits, StatValue.retransmits(s.retransmitPercent),
                            help: L10n.t("Packets sent again after a loss in the last second; high values point at the cable or Wi-Fi",
                                         "최근 1초 동안 손실로 다시 보낸 패킷 비율. 높으면 케이블이나 Wi-Fi 상태를 의심하세요"))
                    }
                }
            }
            // Folded: controls and the frame counts only
            Card(title: StatName.picture, expanded: $showPicture) {
                RoleRows(settings: model.settings, mac: mac, receiver: receiver)
                Row(StatName.frames,
                    "\(Int(s.captureFPS.rounded())) · \(Int(s.sentFPS.rounded())) · \(Int((s.receiver?.displayedFPS ?? 0).rounded()))",
                    help: L10n.t("Per second: frames \(mac) drew, sent, and \(receiver) showed; shown counts redraws too, so it can pass sent",
                                 "초당 프레임: \(mac)에서 그린 것, 보낸 것, \(receiver)에서 표시한 것. 표시에는 다시 그린 것도 들어가 보낸 것보다 많을 수 있습니다"))
                if showPicture {
                    if let verdict = s.highRefresh {
                        Text(HighRefreshLabel.text(verdict)).font(.system(size: 11))
                            .foregroundStyle(verdict == .needsThunderbolt ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Row(StatName.dropped, "\(s.droppedPerMinute)",
                        help: L10n.t("Captures skipped while the link or encoder was busy; their changes go out with the next frame",
                                     "링크나 인코더가 바빠 건너뛴 캡처 프레임 수입니다. 바뀐 내용은 다음 프레임에 함께 보냅니다"))
                    if let c = s.config {
                        Row(StatName.resolution, StatValue.resolution(c.streamPixels),
                            help: L10n.t("The screen is drawn and sent at this size; still areas arrive at it as BC7",
                                         "이 크기로 화면을 그려 보냅니다. 멈춘 영역은 이 크기 그대로 BC7로 보냅니다"))
                        let target = MotionLabel.target(c, videoBitrate: s.videoBitrate)
                        Row(StatName.motion, MotionLabel.text(c, videoBitrate: s.videoBitrate, lossyTiles: s.lossyTiles),
                            help: target != nil
                                ? L10n.t("Moving areas go out as video: the whole screen scaled to this size, scaled back up on \(receiver). Once still, they return at full size as BC7",
                                         "움직이는 영역은 비디오로 보냅니다. 화면 전체를 이 크기로 줄여 인코딩하고 \(receiver)에서 원래 크기로 늘립니다. 멈추면 원래 크기의 BC7로 다시 보냅니다")
                                : L10n.t("BC7 while half the measured link covers it; past that, BC1: same size, half the data, banded gradients",
                                         "링크 실측 속도의 절반 안에서는 BC7로 선명하게, 넘으면 BC1로 보냅니다. BC1은 크기는 같고 데이터는 절반이지만 그라데이션에 띠가 생깁니다"))
                        if let target = target {
                            Row(StatName.videoTarget, target,
                                help: L10n.t("What the video encoder aims for; lowered while the network is busy, raised again after. Data actually sent is the throughput",
                                             "비디오 인코더가 맞추려는 비트레이트입니다. 네트워크가 혼잡하면 낮추고 풀리면 다시 올립니다. 실제로 보낸 양은 전송량을 보세요"))
                        }
                        SwitchRow(title: L10n.t("Show sent blocks on \(receiver)", "\(receiver)에 보낸 블록 표시"), isOn: Binding(get: { model.flashBlocks }, set: { model.flashBlocks = $0 }))
                            .help(L10n.t("For checking: changed blocks flash red, blocks sent again sharper yellow, video blue. Off when Afterscreen starts again",
                                         "확인용: 바뀐 블록은 빨강, 선명하게 다시 보낸 블록은 노랑, 비디오는 파랑으로 잠깐 칠합니다. Afterscreen을 다시 실행하면 꺼집니다"))
                        if let options = s.receiverOptions, options.editable {
                            SwitchRow(title: L10n.t("Show the HUD on \(receiver)", "\(receiver)에 HUD 표시"),
                                      isOn: Binding(get: { options.hud }, set: { model.changeReceiver(ReceiverOptionsChange(hud: $0)) }))
                                .help(L10n.t("Link and frame figures over the picture. ⌥⌘I on \(receiver) also shows or hides them",
                                             "화면 위에 링크와 프레임 정보를 띄웁니다. \(receiver)에서 ⌥⌘I로도 켜고 끕니다"))
                        }
                        Row(StatName.compression, StatValue.compression(s.compressionRatio),
                            help: L10n.t("Tile data size before and after LZ4; 1.0× when the link has room and LZ4 is skipped. Video not included",
                                         "타일 데이터에 LZ4를 건 전후 크기 비율입니다. 링크에 여유가 있으면 LZ4를 쓰지 않아 1.0×입니다. 비디오는 빠집니다"))
                    }
                }
                Row(label: StatName.deband, value: "",
                    help: L10n.t("Fills 8-bit steps in dark gradients on \(receiver), in tile areas only, not in video. Higher reaches wider and uses more of its GPU",
                                 "어두운 그라데이션의 8비트 계단을 \(receiver)에서 부드럽게 메웁니다. 타일로 보낸 영역에만 적용되고 비디오에는 적용되지 않습니다. 강할수록 넓게 메우고 \(receiver) GPU를 더 씁니다")) {
                    Picker("", selection: Binding(get: { model.settings.deband }, set: { model.setDeband($0) })) {
                        ForEach(Deband.allCases, id: \.self) { Text(DebandLabel.name($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if showPicture {
                    Row(StatName.encode, StatValue.encode(s.encodeMs),
                        help: L10n.t("Average per frame in the last second, from processing start until queued to send, video encoding included",
                                     "최근 1초 평균입니다. 프레임 처리를 시작해 송신 대기열에 넣기까지 걸린 시간이며 비디오 인코딩도 들어갑니다"))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: StatName.resources, expanded: $showResources)
                if showResources {
                    Box {
                        Row(mac, StatValue.usage(cpu: s.cpuPercent, memory: s.memoryBytes, gpu: s.gpuPercent),
                            help: L10n.t("This app only. CPU: one core is 100%. GPU: tile encoding; video encoding not included",
                                         "이 앱만 셉니다. CPU는 코어 하나가 100%입니다. GPU는 타일 인코딩 시간이며 비디오 인코딩은 빠집니다"))
                        if let r = s.receiver {
                            Row(receiver, StatValue.usage(cpu: r.cpuPercent, memory: r.memoryBytes, gpu: r.gpuPercent),
                                help: L10n.t("This app only. CPU: one core is 100%. GPU: drawing the screen; video decoding not included",
                                             "이 앱만 셉니다. CPU는 코어 하나가 100%입니다. GPU는 화면을 그리는 시간이며 비디오 디코딩은 빠집니다"))
                            Row(StatName.upload(receiver), StatValue.upload(r.uploadMs, decompress: r.decompressMs),
                                help: L10n.t("Latest tile frame on \(receiver): preparing the upload · LZ4 decompression. Video decoding not included",
                                             "\(receiver)에서 마지막 타일 프레임을 처리한 시간: 업로드 준비 · LZ4 해제. 비디오 디코딩은 빠집니다"))
                        } else {
                            Row(receiver, L10n.t("waiting for stats", "통계 기다리는 중"))
                        }
                    }
                }
            }
            if let p = s.peer {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(title: L10n.t("\(model.receiverName) hardware", "\(model.receiverName) 하드웨어"), expanded: $showHardware)
                    if showHardware {
                        Box {
                            Row(L10n.t("Model", "모델"), p.marketingName, mono: false)
                            Row(L10n.t("Model identifier", "모델 식별자"), p.modelID)
                            Row(L10n.t("Panel", "패널"), StatValue.resolution(p.panelPixels))
                            Row("GPU", p.gpuNames.joined(separator: ", "), mono: false)
                            Row("macOS", p.osVersion)
                            Row(L10n.t("Hardware video decode", "하드웨어 영상 디코딩"), HardwareDecodeLabel.text(p), mono: false)
                        }
                    }
                }
            }
        }
    }
}

/// The high-refresh experiment's outcome, one line
enum HighRefreshLabel {
    static func text(_ verdict: HighRefresh.Verdict) -> String {
        let ms = { (v: Double) in String(format: "%.1f", v) }
        switch verdict {
        case .high(let t):
            return L10n.t("120 fps experiment: encoding takes \(ms(t)) ms, sending at 120 fps",
                          "120fps 실험: 인코딩 \(ms(t))ms로 여유가 있어 120fps로 보냅니다")
        case .encoderBusy(let t?):
            return L10n.t("120 fps experiment: encoding takes \(ms(t)) ms, too long for 120; sending at 60 fps",
                          "120fps 실험: 인코딩이 프레임당 \(ms(t))ms라 여유가 없어 60fps로 보냅니다")
        case .encoderBusy(nil):
            return L10n.t("120 fps experiment: the encoder could not be timed; sending at 60 fps",
                          "120fps 실험: 인코더를 측정하지 못해 60fps로 보냅니다")
        case .needsThunderbolt:
            return L10n.t("120 fps experiment: Thunderbolt only; sending at 60 fps",
                          "120fps 실험: Thunderbolt 연결에서만 켜집니다. 지금은 60fps로 보냅니다")
        case .linkTooSlow(let gbps):
            return L10n.t("120 fps experiment: the link measured \(String(format: "%.1f", gbps)) Gbps, too slow for lossless 120 fps; sending at 60 fps",
                          "120fps 실험: 링크 실측 \(String(format: "%.1f", gbps))Gbps로 120fps 무손실에 부족해 60fps로 보냅니다")
        }
    }
}
