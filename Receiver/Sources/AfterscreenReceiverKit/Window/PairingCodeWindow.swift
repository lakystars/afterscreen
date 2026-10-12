import AfterscreenCore
import AppKit

/// The pairing code on this Mac's screen, above everything
/// Shown while a sender's user types it
final class PairingCodeWindow {
    private var panel: NSPanel?

    /// `screen`: where the stream will show; nil: the key screen
    func show(code: String, sender: String, on screen: NSScreen?) {
        hide()
        let size = NSSize(width: 620, height: 290)
        let target = screen ?? NSScreen.main
        let frame = target?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Centred, relative to the screen's origin as `screen:` takes it
        let panel = NSPanel(contentRect: NSRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: target)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Stays up while another app is active
        panel.hidesOnDeactivate = false
        // Every Space, over a full-screen stream too
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        // A mask, not a layer radius: macOS 13 kept a square frame
        background.maskImage = PairingCodeWindow.roundedMask(radius: 18)
        // "123 456": two groups read aloud more easily
        let digits = code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
        // Mac named once, in the title; then where to type
        let rows: [(String, NSFont)] = [
            (L10n.t("\(sender) wants to use \(ComputerName.current)", "\(sender)에서 \(ComputerName.current)에 연결하려고 합니다"), .systemFont(ofSize: 20, weight: .semibold)),
            (digits, .monospacedDigitSystemFont(ofSize: 72, weight: .bold)),
            // The sender opens its code boxes by itself
            (L10n.t("Type this code into the boxes now open on that Mac", "그 Mac에 뜬 입력 칸에 이 코드를 입력하세요"), .systemFont(ofSize: 16)),
        ]
        let stack = NSStackView(views: rows.map { text, font in
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.alignment = .center
            label.textColor = .labelColor
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = size.width - 56
            return label
        })
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width - 56),
        ])
        panel.contentView = background
        // Shadow follows the mask, not the frame
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Stretchable rounded rectangle; its alpha masks the material
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
