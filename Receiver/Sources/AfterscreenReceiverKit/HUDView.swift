import AppKit
import AfterscreenCore
import SwiftUI

/// The HUD panel: the sender popover's cards in dark, over the stream. macOS 10.15 SwiftUI only
struct HUDView: View {
    var content: HUDContent
    var collapsed: Bool

    static let width: CGFloat = 360
    /// Clicks this far from the top fold or unfold the HUD
    static let titleZone: CGFloat = 40

    private static let text = Color(white: 0.95)
    private static let dim = Color(white: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !collapsed {
                ForEach(content.sections.indices, id: \.self) { i in self.card(self.content.sections[i]) }
                Text(L10n.t("Drag to move · click the title to fold · ⌥⌘I hides", "끌어서 이동 · 제목 클릭으로 접기 · ⌥⌘I 숨김"))
                    .font(.system(size: 10))
                    .foregroundColor(HUDView.dim)
            }
        }
        .padding(12)
        .frame(width: HUDView.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.07, opacity: 0.88)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 1, opacity: 0.14), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("●").font(.system(size: 9)).foregroundColor(content.testing ? .orange : .green)
            if collapsed {
                Text(content.summary).font(.system(size: 12, design: .monospaced)).foregroundColor(HUDView.text).lineLimit(1)
            } else {
                Text(content.title).font(.system(size: 13, weight: .semibold)).foregroundColor(HUDView.text).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !collapsed {
                Text(content.status).font(.system(size: 11)).foregroundColor(content.testing ? .orange : .green)
            }
            Text(collapsed ? "▸" : "▾").font(.system(size: 11)).foregroundColor(HUDView.dim)
        }
        .frame(height: 18)
    }

    private func card(_ section: HUDContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundColor(HUDView.dim)
            VStack(spacing: 4) {
                ForEach(section.rows.indices, id: \.self) { i in self.row(section.rows[i]) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 1, opacity: 0.07)))
        }
    }

    private func row(_ r: HUDContent.Row) -> some View {
        HStack(spacing: 6) {
            Text(r.label).font(.system(size: 12)).foregroundColor(HUDView.dim).lineLimit(1)
            Spacer(minLength: 4)
            if r.link != nil { LinkMark(kind: r.link).foregroundColor(color(r.tone)) }
            Text(r.value).font(.system(size: 12, design: .monospaced)).foregroundColor(color(r.tone)).lineLimit(1)
            if r.graph != nil {
                HUDSparkline(values: r.graph ?? [], color: color(r.graphColor)).frame(width: 52, height: 14)
            }
        }
    }

    private func color(_ tone: HUDContent.Tone) -> Color {
        switch tone {
        case .plain: return HUDView.text
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }

    private func color(_ graph: HUDContent.GraphColor) -> Color {
        switch graph {
        case .green: return Color(red: 0.3, green: 0.85, blue: 0.45)
        case .blue: return Color(red: 0.35, green: 0.65, blue: 1)
        case .purple: return Color(red: 0.75, green: 0.55, blue: 1)
        }
    }
}

/// The link's SF Symbol from macOS 11, its text glyph before
private struct LinkMark: View {
    var kind: LinkKind?

    var body: some View {
        Group {
            if #available(macOS 11, *) {
                Image(systemName: LinkLabel.symbol(kind) ?? "questionmark").font(.system(size: 11))
            } else {
                Text(LinkLabel.glyph(kind)).font(.system(size: 12))
            }
        }
    }
}

/// Values scaled to their maximum, oldest on the left
private struct HUDSparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard self.values.count > 1, let top = self.values.max(), top > 0 else { return }
                let step = geo.size.width / CGFloat(self.values.count - 1)
                for (i, v) in self.values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / top)))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(self.color, lineWidth: 1.3)
        }
    }
}

/// Hosts the HUD: a drag moves it, a click on its title folds it, a right-click opens the stream menu.
/// SwiftUI gets no mouse events; the HUD has no controls
final class HUDHostView: NSHostingView<HUDView> {
    var onDrop: ((CGRect) -> Void)?
    var onTitleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var isDragging = false
    private var grab: NSPoint?
    private var startOrigin = NSPoint.zero

    required init(rootView: HUDView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grab = superview?.convert(event.locationInWindow, from: nil)
        startOrigin = frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = grab, let p = superview?.convert(event.locationInWindow, from: nil) else { return }
        let dx = p.x - grab.x, dy = p.y - grab.y
        // A shaky click is not a drag
        if !isDragging && hypot(dx, dy) < 3 { return }
        if !isDragging { NSCursor.closedHand.push() }
        isDragging = true
        setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        if isDragging {
            NSCursor.pop()
            isDragging = false
            onDrop?(frame)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        if fromTop <= HUDView.titleZone { onTitleClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
