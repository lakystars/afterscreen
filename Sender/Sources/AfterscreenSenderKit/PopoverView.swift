import AppKit
import AfterscreenCore
import SwiftUI

enum LinkLabel {
    static func glyph(_ kind: LinkKind?) -> String {
        switch kind {
        case .thunderbolt?: return "ϟ"
        case .usb?: return "⌁"
        case .wifi?: return "≋"
        case .loopback?: return "↺"
        default: return "?"
        }
    }

    static func name(_ kind: LinkKind?) -> String {
        switch kind {
        case .thunderbolt?: return "Thunderbolt"
        case .usb?: return "USB"
        case .wifi?: return "Wi-Fi"
        case .loopback?: return "Loopback (same Mac)"
        case .unsupported?: return "Unsupported"
        case nil: return "—"
        }
    }
}

extension Format {
    static func compactGbps(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1e9 ? String(format: "%.1fG", bitsPerSecond / 1e9) : String(format: "%.0fM", bitsPerSecond / 1e6)
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

private struct Row<Trailing: View>: View {
    var label: String
    var value: String
    var valueColor: Color = .primary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(valueColor)
            trailing()
        }
        .font(.system(size: 12))
    }
}

private extension Row where Trailing == EmptyView {
    init(_ label: String, _ value: String, color: Color = .primary) {
        self.init(label: label, value: value, valueColor: color) { EmptyView() }
    }
}

private struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

public struct PopoverView: View {
    @ObservedObject var model: AppModel
    @State private var showHardware = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isActive || model.snapshot.isStreaming {
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
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Afterscreen").font(.headline)
            if !model.screenRecordingGranted {
                HStack {
                    Text("Screen Recording permission is required").font(.system(size: 12)).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") { model.openPrivacySettings() }
                }
            }
            SectionTitle(text: "Receivers")
            if model.receivers.isEmpty {
                Text("Looking for Afterscreen Receiver… Start it on the iMac and connect a Thunderbolt or USB cable.")
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
                    Button("Connect") { model.connect(r) }
                }
            }
        }
    }

    private var streamingBody: some View {
        let s = model.snapshot
        let scoreColor: Color = (s.cableScore ?? 100) >= 80 ? .green : ((s.cableScore ?? 100) >= 50 ? .yellow : .red)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.peer?.marketingName ?? model.activeReceiver ?? "Receiver").font(.headline)
                Spacer()
                Text(s.isStreaming ? "● Streaming" : s.state).font(.system(size: 11))
                    .foregroundStyle(s.isStreaming ? .green : .secondary)
            }
            Divider()
            SectionTitle(text: "Connection")
            Row("Method", "\(LinkLabel.glyph(s.link)) \(LinkLabel.name(s.link)) · \(s.interface ?? "—")")
            if let mtu = s.mtu {
                let advice = LinkMetrics.mtuAdvice(mtu: mtu, link: s.link)
                Row("MTU", advice.map { "\(mtu) · \($0)" } ?? "\(mtu)", color: advice == nil ? .primary : .orange)
            }
            Row("Cable quality", s.cableScore.map { "\($0) / 100" } ?? "—", color: scoreColor)
            Row(label: "Throughput", value: Format.gbps(bytesPerSecond: s.throughputBitsPerSecond / 8)) {
                Sparkline(values: s.throughputHistory, color: .green)
            }
            Row(label: "Latency (RTT)", value: s.latencyMs.map(Format.ms) ?? "—") {
                Sparkline(values: s.latencyHistory, color: .blue)
            }
            Row("Jitter", Format.ms(s.jitterMs))
            Row("Capacity (probe)", s.capacityGbps.map { String(format: "%.2f Gbps", $0) } ?? "—")
            Row("Retransmits", String(format: "%.2f%%", s.retransmitPercent))
            SectionTitle(text: "Frames")
            Row("Capture → sent → shown",
                "\(Int(s.captureFPS.rounded())) · \(Int(s.sentFPS.rounded())) · \(Int((s.receiver?.displayedFPS ?? 0).rounded()))")
            Row("Dropped / min", "\(s.droppedPerMinute)")
            if let c = s.config {
                Row("Path", c.path == .tile ? "Tiles (BC7) \(c.streamPixels.width)×\(c.streamPixels.height)"
                    : "\(c.codec?.rawValue.uppercased() ?? "Video") \(c.streamPixels.width)×\(c.streamPixels.height)")
                if c.path == .tile {
                    Row("Changed tiles", String(format: "%.0f%%", s.dirtyPercent))
                    Row("Compression", s.compressionRatio > 0 ? String(format: "%.1f×", s.compressionRatio) : "—")
                }
            }
            Row("Encode", Format.ms(s.encodeMs))
            SectionTitle(text: "This app (sender)")
            Row("CPU · RAM · GPU", "\(Format.percent(s.cpuPercent)) · \(Format.bytes(s.memoryBytes)) · \(Format.percent(s.gpuPercent))")
            SectionTitle(text: "Receiver app")
            if let r = s.receiver {
                Row("CPU · RAM · GPU", "\(Format.percent(r.cpuPercent)) · \(Format.bytes(r.memoryBytes)) · \(Format.percent(r.gpuPercent))")
                Row("Upload · decompress", "\(Format.ms(r.uploadMs)) · \(Format.ms(r.decompressMs))")
            } else {
                Row("Status", "waiting for stats")
            }
            DisclosureGroup(isExpanded: $showHardware) {
                if let p = s.peer {
                    VStack(alignment: .leading, spacing: 3) {
                        Row("Model", "\(p.marketingName) (\(p.modelID))")
                        Row("Panel", "\(p.panelPixels.width)×\(p.panelPixels.height)")
                        Row("GPU", p.gpuNames.joined(separator: ", "))
                        Row("macOS", p.osVersion)
                        Row("Decode", "BC7 · HEVC \(p.hevcDecode ? "✓" : "✗") · H.264 \(p.h264Decode ? "✓" : "✗")")
                    }
                }
            } label: {
                Text("Hardware").font(.system(size: 12, weight: .medium))
            }
            HStack {
                Spacer()
                Button("Disconnect") { model.disconnect() }
            }
        }
    }
}
