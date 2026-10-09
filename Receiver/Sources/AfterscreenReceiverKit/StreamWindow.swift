import AppKit
import AfterscreenCore
import QuartzCore

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Layer-hosting view: Metal picture, cursor and HUD layers
private final class StreamView: NSView {
    var onLayout: ((CGRect, CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onLayout?(bounds, window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?(bounds, window?.backingScaleFactor ?? 2)
    }
}

/// Fullscreen stream window on the main display, with cursor and HUD overlays
final class StreamWindow {
    var onExitRequest: (() -> Void)?
    var hudText: (() -> String)?

    private let window: KeyWindow
    private let view = StreamView()
    private let root = CALayer()
    private let cursorLayer = CALayer()
    private let hudLayer = CATextLayer()
    private var keyMonitor: Any?
    private var hudTimer: Timer?
    private var lastEscape = Date.distantPast
    private var cursorImage: CursorImage?
    private var cursorNormalized: (x: Float, y: Float, visible: Bool) = (0, 0, false)
    private var contentPixels = CGSize.zero
    private var sourcePoints = CGSize.zero

    private let windowed: Bool

    /// `windowed` opens a normal resizable window (development on one Mac)
    init(renderer: StreamRenderer, windowed: Bool) {
        self.windowed = windowed
        let frame = windowed ? NSRect(x: 80, y: 80, width: 1280, height: 760)
            : (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800))
        window = KeyWindow(contentRect: frame, styleMask: windowed ? [.titled, .resizable, .miniaturizable] : .borderless,
                           backing: .buffered, defer: false)
        window.title = "Afterscreen Receiver"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.layer = root
        view.wantsLayer = true
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(renderer.layer)

        cursorLayer.isHidden = true
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        cursorLayer.magnificationFilter = .linear
        root.addSublayer(cursorLayer)

        hudLayer.isHidden = true
        hudLayer.backgroundColor = CGColor(gray: 0.08, alpha: 0.8)
        hudLayer.foregroundColor = CGColor(gray: 0.95, alpha: 1)
        hudLayer.cornerRadius = 8
        hudLayer.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hudLayer.fontSize = 12
        hudLayer.alignmentMode = .left
        hudLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(hudLayer)

        window.contentView = view
        view.onLayout = { [weak self, weak renderer] bounds, scale in
            renderer?.layout(bounds: bounds, scale: scale)
            self?.hudLayer.contentsScale = scale
            self?.placeCursor()
            self?.placeHUD()
        }
    }

    func show(config: StreamConfig) {
        contentPixels = CGSize(width: config.streamPixels.width, height: config.streamPixels.height)
        sourcePoints = CGSize(width: config.sourcePoints.width, height: config.sourcePoints.height)
        NSApp.activate(ignoringOtherApps: true)
        if !windowed {
            if let screen = NSScreen.main { window.setFrame(screen.frame, display: true) }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            NSCursor.hide()
        }
        window.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshHUD() }
        view.needsLayout = true
    }

    func hide() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        hudTimer?.invalidate()
        hudTimer = nil
        cursorLayer.isHidden = true
        if window.isVisible && !windowed { NSCursor.unhide() }
        window.orderOut(nil)
        if !windowed { NSApp.presentationOptions = [] }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // Esc
            let now = Date()
            if now.timeIntervalSince(lastEscape) < 1 { onExitRequest?() }
            lastEscape = now
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "i" {
            hudLayer.isHidden.toggle()
            refreshHUD()
            return nil
        }
        return event
    }

    // MARK: - Cursor

    func setCursor(x: Float, y: Float, visible: Bool) {
        cursorNormalized = (x, y, visible)
        placeCursor()
    }

    func setCursorImage(_ image: CursorImage) {
        cursorImage = image
        cursorLayer.contents = NSImage(data: image.png)
        let w = max(1, CGFloat(image.width)), h = max(1, CGFloat(image.height))
        cursorLayer.anchorPoint = CGPoint(x: CGFloat(image.hotX) / w, y: 1 - CGFloat(image.hotY) / h)
        placeCursor()
    }

    private var videoRect: CGRect {
        RenderGeometry.aspectFit(content: contentPixels, in: view.bounds)
    }

    private func placeCursor() {
        guard let image = cursorImage, sourcePoints.width > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let rect = videoRect
        let scale = rect.width / sourcePoints.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        cursorLayer.position = CGPoint(x: rect.minX + CGFloat(cursorNormalized.x) * rect.width,
                                       y: rect.maxY - CGFloat(cursorNormalized.y) * rect.height)
        cursorLayer.isHidden = !cursorNormalized.visible
        CATransaction.commit()
    }

    // MARK: - HUD

    private func refreshHUD() {
        guard !hudLayer.isHidden, let text = hudText?() else { return }
        hudLayer.string = text
        placeHUD()
    }

    private func placeHUD() {
        let lines = CGFloat(((hudLayer.string as? String) ?? "").split(separator: "\n").count)
        let size = CGSize(width: 300, height: max(1, lines) * 16 + 16)
        hudLayer.frame = CGRect(x: view.bounds.maxX - size.width - 16, y: view.bounds.maxY - size.height - 16,
                                width: size.width, height: size.height)
    }
}
