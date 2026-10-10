import AppKit
import AfterscreenCore
import QuartzCore

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Layer-hosting view: Metal picture, cursor and hint layers
private final class StreamView: NSView {
    var onLayout: ((CGRect, CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// This Mac's own pointer over the stream; nil keeps the system's
    var pointer: NSCursor?

    override func layout() {
        super.layout()
        onLayout?(bounds, window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?(bounds, window?.backingScaleFactor ?? 2)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func resetCursorRects() {
        if let pointer = pointer { addCursorRect(bounds, cursor: pointer) }
    }
}

/// Fullscreen stream window on the main display, with cursor, hint and HUD overlays.
/// A new window per session: a closed full-screen window leaves no state behind
final class StreamWindow {
    /// Window setup for each presentation
    struct Style {
        let mask: NSWindow.StyleMask
        let level: NSWindow.Level
        let behavior: NSWindow.CollectionBehavior
        /// The system's full screen: a Space of its own
        let fullScreen: Bool
        private let windowed: Bool

        init(presentation: ReceiverSettings.Presentation, windowed: Bool) {
            self.windowed = windowed
            if windowed {
                mask = [.titled, .resizable, .miniaturizable]
                level = .normal
                behavior = [.fullScreenAuxiliary]
                fullScreen = false
            } else if presentation == .space {
                mask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                level = .normal
                behavior = [.fullScreenPrimary, .managed]
                fullScreen = true
            } else {
                // A menu bar app never owns the menu bar, so presentation options cannot hide it:
                // the stream sits above the menu bar and Dock instead
                mask = .borderless
                level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
                behavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
                fullScreen = false
            }
        }

        /// Full screen grows from a centred window three fifths of the screen, so the system animates it
        /// as for any app; covering takes the whole screen at once
        func initialFrame(in screen: NSRect) -> NSRect {
            if windowed { return NSRect(x: 80, y: 80, width: 1280, height: 760) }
            guard fullScreen else { return screen }
            let size = NSSize(width: (screen.width * 0.6).rounded(), height: (screen.height * 0.6).rounded())
            return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Targets of the stream's right-click menu
    final class MenuActions: NSObject {
        var stop: (() -> Void)?
        var toggleHUD: (() -> Void)?
        var settings: (() -> Void)?

        @objc func stopStream() { stop?() }
        @objc func toggleHeadsUp() { toggleHUD?() }
        @objc func openSettings() { settings?() }
    }

    static func makeMenu(hudShown: Bool, target: MenuActions?) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target
            menu.addItem(i)
        }
        item(L10n.t("Stop the stream", "스트림 중지"), #selector(MenuActions.stopStream))
        item(hudShown ? L10n.t("Hide the HUD", "HUD 숨기기") : L10n.t("Show the HUD", "HUD 보기"), #selector(MenuActions.toggleHeadsUp))
        menu.addItem(.separator())
        item(L10n.t("Settings…", "설정…"), #selector(MenuActions.openSettings))
        return menu
    }

    /// This Mac's pointer over a stream in its own Space: a ring, so it is not taken for the sender's pointer
    static let localPointer: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            ring.lineWidth = 3
            NSColor(white: 0, alpha: 0.5).setStroke()
            ring.stroke()
            ring.lineWidth = 1.5
            NSColor(white: 1, alpha: 0.9).setStroke()
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()

    var onExitRequest: (() -> Void)?
    var onSettingsRequest: (() -> Void)?
    var hudContent: (() -> HUDContent?)?
    /// Where the HUD sits and whether it is folded; reported back on change for the settings
    var hudCorner = ReceiverSettings.HUDCorner.topRight
    var hudCollapsed = false
    var onHUDChange: ((ReceiverSettings.HUDCorner, Bool) -> Void)?
    /// Main queue: false while the window is on another Space or covered
    var onVisibilityChange: ((Bool) -> Void)?
    /// Applies at the next session's first show
    var presentation = ReceiverSettings.Presentation.space

    private var window: KeyWindow?
    /// Holds the stream view and the HUD above it: a layer-hosting view takes no subviews
    private let container = NSView()
    private let view = StreamView()
    private let root = CALayer()
    private let cursorLayer = CALayer()
    private let hud = HUDHostView(rootView: HUDView(content: .empty, collapsed: false))
    private let hintLayer = CATextLayer()
    private var keyMonitor: Any?
    private var hudTimer: Timer?
    private var lastEscape = Date.distantPast
    private var cursorImage: CursorImage?
    private var cursorNormalized: (x: Float, y: Float, visible: Bool) = (0, 0, false)
    private var contentPixels = CGSize.zero
    /// The HUD was shown for a quality test, not by the user
    private var forcedHUD = false
    private var cursorHidden = false
    private var mouseMonitor: Any?
    private var idleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let actions = MenuActions()

    private let windowed: Bool

    /// `windowed` opens a normal resizable window (development on one Mac)
    init(renderer: StreamRenderer, windowed: Bool) {
        self.windowed = windowed
        view.layer = root
        view.wantsLayer = true
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(renderer.layer)

        cursorLayer.isHidden = true
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        cursorLayer.magnificationFilter = .linear
        root.addSublayer(cursorLayer)

        hintLayer.opacity = 0
        hintLayer.backgroundColor = CGColor(gray: 0.08, alpha: 0.8)
        hintLayer.foregroundColor = CGColor(gray: 0.95, alpha: 1)
        hintLayer.cornerRadius = 10
        hintLayer.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        hintLayer.fontSize = 15
        hintLayer.alignmentMode = .center
        hintLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(hintLayer)

        container.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        hud.isHidden = true
        hud.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(hud)
        hud.onTitleClick = { [weak self] in
            guard let self = self else { return }
            self.hudCollapsed.toggle()
            self.onHUDChange?(self.hudCorner, self.hudCollapsed)
            self.refreshHUD()
        }
        hud.onDrop = { [weak self] frame in self?.dropHUD(frame) }

        actions.stop = { [weak self] in self?.onExitRequest?() }
        actions.toggleHUD = { [weak self] in self?.toggleHUD() }
        actions.settings = { [weak self] in self?.onSettingsRequest?() }
        view.menuProvider = { [weak self] in
            guard let self = self else { return nil }
            return StreamWindow.makeMenu(hudShown: !self.hud.isHidden, target: self.actions)
        }
        hud.menuProvider = view.menuProvider
        view.onLayout = { [weak self, weak renderer] bounds, scale in
            renderer?.layout(bounds: bounds, scale: scale)
            self?.hintLayer.contentsScale = scale
            self?.placeCursor()
            self?.placeHUD()
            self?.placeHint()
        }
    }

    /// Called again for each new config of a session (quality test stages)
    func show(config: StreamConfig) {
        contentPixels = CGSize(width: config.streamPixels.width, height: config.streamPixels.height)
        if config.test && hud.isHidden {
            hud.isHidden = false
            forcedHUD = true
        }
        guard keyMonitor == nil else {
            view.needsLayout = true
            refreshHUD()
            return
        }
        let style = Style(presentation: presentation, windowed: windowed)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = makeWindow(style, frame: style.initialFrame(in: screen))
        NSApp.activate(ignoringOtherApps: true)
        if !windowed && !style.fullScreen {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            NSCursor.hide()
            cursorHidden = true
        }
        window.makeKeyAndOrderFront(nil)
        if style.fullScreen {
            window.toggleFullScreen(nil)
            NSCursor.setHiddenUntilMouseMoves(true)
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDown]) { [weak self] event in
                self?.scheduleCursorHide()
                return event
            }
        }
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
        if forcedHUD { hud.isHidden = true }
        forcedHUD = false
        hintLayer.removeAllAnimations()
        hintLayer.opacity = 0
        if cursorHidden { NSCursor.unhide() }
        cursorHidden = false
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        guard let window = window else { return }
        // Closing a full-screen window leaves its Space with the system's own transition back
        if window.styleMask.contains(.fullScreen) { window.close() } else { window.orderOut(nil) }
        if !windowed { NSApp.presentationOptions = [] }
    }

    private func makeWindow(_ style: Style, frame: NSRect) -> KeyWindow {
        observers.forEach(NotificationCenter.default.removeObserver)
        window?.contentView = nil
        let window = KeyWindow(contentRect: frame, styleMask: style.mask, backing: .buffered, defer: false)
        window.title = "Afterscreen Receiver"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = style.level
        window.collectionBehavior = style.behavior
        window.acceptsMouseMovedEvents = true
        if style.mask.contains(.titled) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        container.frame = NSRect(origin: .zero, size: frame.size)
        view.frame = container.bounds
        view.pointer = style.fullScreen ? StreamWindow.localPointer : nil
        window.contentView = container
        window.invalidateCursorRects(for: view)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window = window else { return }
                self?.onVisibilityChange?(window.occlusionState.contains(.visible))
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.showHint()
            },
        ]
        self.window = window
        return window
    }

    private func scheduleCursorHide() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in NSCursor.setHiddenUntilMouseMoves(true) }
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
            toggleHUD()
            return nil
        }
        return event
    }

    private func toggleHUD() {
        hud.isHidden.toggle()
        refreshHUD()
    }

    // MARK: - Hint

    /// How to leave the stream's Space, for three seconds after it opens
    private func showHint() {
        hintLayer.string = L10n.t("Control + ← → switches to this Mac's desktop · right-click for the menu",
                                  "Control + ← →로 이 Mac 데스크톱과 전환 · 우클릭으로 메뉴")
        placeHint()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.85, 1]
        fade.duration = 3.5
        hintLayer.add(fade, forKey: "hint")
    }

    private func placeHint() {
        let size = CGSize(width: 620, height: 44)
        hintLayer.frame = CGRect(x: view.bounds.midX - size.width / 2, y: 64, width: size.width, height: size.height)
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
        guard let image = cursorImage, contentPixels.width > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let rect = videoRect
        // Cursor sizes arrive in stream pixels
        let scale = rect.width / contentPixels.width
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
        guard !hud.isHidden, let content = hudContent?() else { return }
        hud.rootView = HUDView(content: content, collapsed: hudCollapsed)
        placeHUD()
    }

    private func placeHUD() {
        guard !hud.isHidden, !hud.isDragging else { return }
        hud.frame = HUDPlacement.frame(size: hud.fittingSize, corner: hudCorner, in: container.bounds)
    }

    private func dropHUD(_ frame: CGRect) {
        hudCorner = HUDPlacement.nearest(to: frame, in: container.bounds)
        onHUDChange?(hudCorner, hudCollapsed)
        let target = HUDPlacement.frame(size: frame.size, corner: hudCorner, in: container.bounds)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().frame = target
        }
    }
}
