import AppKit
import AfterscreenCore
import QuartzCore

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Layer-hosting view: picture, cursor, hint and notice layers
private final class StreamView: NSView {
    var onLayout: ((CGRect, CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// This Mac's pointer over the stream; nil keeps the system's
    var pointer: NSCursor?

    /// Before a window: the screen's, not an assumed Retina 2
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }

    override func layout() {
        super.layout()
        onLayout?(bounds, scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?(bounds, scale)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func resetCursorRects() {
        if let pointer = pointer { addCursorRect(bounds, cursor: pointer) }
    }
}

/// Whether a window's picture is up
/// Each window powers on once and off once
struct PowerSequence {
    private(set) var on = false

    /// false if already on
    mutating func powerOn() -> Bool {
        guard !on else { return false }
        on = true
        return true
    }

    /// true: play `effect`'s power-off before the window closes
    /// Off either way: the next window powers on
    mutating func powerOff(effect: ReceiverSettings.Effect) -> Bool {
        defer { on = false }
        return on && effect != .none
    }
}

/// Fullscreen stream window on the chosen screen
/// Cursor, hint and HUD overlays
/// New window per session: closed full-screen windows leave no state
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
                // Menu bar apps never own the menu bar
                // so presentation options cannot hide it
                // The stream sits above the menu bar and Dock instead
                mask = .borderless
                level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
                behavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
                fullScreen = false
            }
        }

        /// Full screen grows from a centred 3/5-size window
        /// The system then animates it as for any app
        /// Cover takes the whole screen at once
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

    /// This Mac's pointer over the stream, while it moves
    /// A ring: distinct from the sender's pointer
    /// A cursor rect, not NSCursor.hide: no counts to unbalance
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
    var hudCorner = ReceiverSettings.HUDCorner.topRight
    var hudCollapsed = false
    /// Reports HUD corner and fold changes for the settings
    var onHUDChange: ((ReceiverSettings.HUDCorner, Bool) -> Void)?
    /// Main queue: HUD toggled here or by the sender
    var onHUDToggle: ((Bool) -> Void)?
    /// Main queue: set as a sender asks
    var hudShown: Bool {
        get { !hud.isHidden }
        set {
            guard newValue == hud.isHidden else { return }
            // Chosen now: a quality test's end keeps it
            forcedHUD = false
            toggleHUD()
        }
    }
    /// Main queue: false while on another Space or covered
    var onVisibilityChange: ((Bool) -> Void)?
    /// Main queue: picture powered on and on screen
    var onShownChange: ((Bool) -> Void)?
    /// Applies at the next session's first show
    var presentation = ReceiverSettings.Presentation.space
    /// Applies at the next session's first show
    /// nil: the screen with keyboard focus
    var display: CGDirectDisplayID?
    /// Applies at the next session's first show
    var matchPanelMode = true
    /// Applies at the next session's first show
    var effect = ReceiverSettings.Effect.tiles
    /// Main queue: a live redraw while the tile wave opens
    var onWaveRedraw: (() -> Void)? {
        get { wave.requestRedraw }
        set { wave.requestRedraw = newValue }
    }
    /// The stream's pointer follows at once
    /// Animated anchors would slide new shapes onto their hot spot
    static let cursorActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                                    "anchorPoint": NSNull()]
    /// Longest power-off duration, for steps waiting on it
    static let longestOff = TileWave.offDuration

    private var window: KeyWindow?
    /// Holds the stream view and the HUD above it
    /// A layer-hosting view takes no subviews
    private let container = NSView()
    private let view = StreamView()
    private let root = CALayer()
    private let cursorLayer = CALayer()
    private let hud = HUDHostView(rootView: HUDView(content: .empty, collapsed: false))
    /// Box and its text: text layers draw from the top
    /// The text is sized to itself, centred in the box
    private let hintLayer = CALayer()
    private let hintText = CATextLayer()
    private static let hintFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    /// Congestion notice: a box of one or two centred lines
    private let noticeBox = CALayer()
    private let noticeText = CATextLayer()
    private let wave: TileWave
    /// The effect of the window on screen
    private var shownEffect = ReceiverSettings.Effect.tiles
    /// Stream pointer hidden until the tile wave has opened
    /// Otherwise it shows alone over black
    private var cursorSuppressed = false
    private var power = PowerSequence()
    /// Bumped per window: earlier sessions' delayed steps become no-ops
    private var generation = 0
    /// The window closing once its power-off has played
    private var closing: (window: KeyWindow, work: DispatchWorkItem)?
    /// Sender's power-off end, media time; an end waits for it
    private var poweredOffAt: CFTimeInterval = 0
    /// Power-off due if a link-switching sender does not return
    private var held: DispatchWorkItem?
    /// How long a sender switching links has to reconnect
    static let relinkWait: TimeInterval = 8
    private var keyMonitor: Any?
    private var hudTimer: Timer?
    private var lastEscape = Date.distantPast
    private var cursorImage: CursorImage?
    private var cursorNormalized: (x: Float, y: Float, visible: Bool) = (0, 0, false)
    private var contentPixels = CGSize.zero
    /// HUD shown for a quality test, not by the user
    private var forcedHUD = false
    private var mouseMonitor: Any?
    private var idleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Screens waking: a refused activation is tried again
    private var wakeObserver: NSObjectProtocol?
    private let actions = MenuActions()
    private let panelMode = PanelMode()
    /// Mode put back once a closed Space has slid away
    private var restoreMode: DispatchWorkItem?
    /// Waiting for screen frames after a mode switch
    private var opening = false

    private let windowed: Bool

    /// `windowed` opens a normal resizable window (development on one Mac)
    init(renderer: StreamRenderer, windowed: Bool) {
        self.windowed = windowed
        wave = TileWave(renderer: renderer)
        view.layer = root
        view.wantsLayer = true
        root.backgroundColor = CGColor(gray: 0, alpha: 1)

        cursorLayer.isHidden = true
        cursorLayer.actions = StreamWindow.cursorActions
        cursorLayer.magnificationFilter = .linear
        root.addSublayer(renderer.layer)
        root.addSublayer(cursorLayer)

        hintLayer.opacity = 0
        hintLayer.backgroundColor = CGColor(gray: 0.08, alpha: 0.8)
        hintLayer.cornerRadius = 10
        hintLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        hintText.foregroundColor = CGColor(gray: 0.95, alpha: 1)
        hintText.font = StreamWindow.hintFont
        hintText.fontSize = StreamWindow.hintFont.pointSize
        hintText.alignmentMode = .center
        hintText.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        hintLayer.addSublayer(hintText)
        root.addSublayer(hintLayer)
        noticeBox.opacity = 0
        noticeBox.backgroundColor = CGColor(gray: 0.08, alpha: 0.85)
        noticeBox.cornerRadius = 12
        noticeText.alignmentMode = .center
        noticeText.isWrapped = true
        for layer in [noticeBox, noticeText] { layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()] }
        noticeBox.addSublayer(noticeText)
        root.addSublayer(noticeBox)

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
            renderer?.layout(bounds: bounds, scale: scale, topInset: self?.notchInset ?? 0)
            self?.hintText.contentsScale = scale
            self?.noticeText.contentsScale = scale
            self?.placeCursor()
            self?.placeHUD()
            self?.placeHint()
            self?.placeNotice()
        }
    }

    /// Called again per new session config (quality test stages)
    func show(config: StreamConfig) {
        held?.cancel()
        held = nil
        poweredOffAt = 0
        // A sender back on a held picture: colour returns
        endWaiting()
        contentPixels = CGSize(width: config.streamPixels.width, height: config.streamPixels.height)
        if config.test && hud.isHidden {
            hud.isHidden = false
            forcedHUD = true
            onHUDToggle?(true)
        }
        guard keyMonitor == nil, !opening else {
            view.needsLayout = true
            refreshHUD()
            return
        }
        closeNow()
        // A new session keeps the switched mode
        restoreMode?.cancel()
        restoreMode = nil
        generation += 1
        guard !windowed, matchPanelMode, let id = display, let size = panelMode.match(id) else {
            // Turned off while the last session's mode was kept
            if windowed || !matchPanelMode { panelMode.restore() }
            return open()
        }
        opening = true
        let session = generation
        whenScreen(id, reaches: size) { [weak self] in
            guard let self = self, self.generation == session else { return }
            self.opening = false
            self.open()
        }
    }

    /// Screen frames follow a mode switch a moment later
    /// Waits for the new size, two seconds at most
    private func whenScreen(_ id: CGDirectDisplayID, reaches size: CGSize, _ body: @escaping () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func check() {
            let now = NSScreen.screens.first { $0.displayID == id }?.frame.size
            guard now != size, ProcessInfo.processInfo.systemUptime < deadline else { return body() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        check()
    }

    private func open() {
        // Nothing carries over from an earlier window's effect
        shownEffect = effect
        cursorSuppressed = shownEffect == .tiles
        switch shownEffect {
        case .tiles: wave.prepare()
        case .none: wave.finish()
        }
        hud.alphaValue = 0
        let style = Style(presentation: presentation, windowed: windowed)
        let target = display.flatMap { id in NSScreen.screens.first { $0.displayID == id } } ?? NSScreen.main
        let screen = target?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = makeWindow(style, frame: style.initialFrame(in: screen), on: target)
        NSApp.activate(ignoringOtherApps: true)
        if !windowed && !style.fullScreen {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.makeKeyAndOrderFront(nil)
        if style.fullScreen {
            // Power-on runs once the Space has slid in
            window.toggleFullScreen(nil)
            retryFullScreen(window)
        }
        if !windowed {
            // Shown while it moves, as to drag the HUD
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
        if !style.fullScreen { powerOn() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.claimFocus() }
    }

    /// Active app, key window: keys and the pointer's cursor rect
    /// Refused while the screen sleeps, as at a wake's reconnect
    private func claimFocus() {
        // Not when its Space was left on purpose
        guard !windowed, let window = window, window.isOnActiveSpace, keyMonitor != nil,
              !(NSApp.isActive && window.isKeyWindow) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Sender switching links: everything stays up for its next session
    /// `show` picks it up; if none comes, power-off, then `expired`
    func hold(for seconds: TimeInterval, expired: @escaping () -> Void) {
        held?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.held = nil
            self?.hide()
            expired()
        }
        held = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Full screen fails while another Space is still sliding away
    /// Retries once, after the slide
    private func retryFullScreen(_ window: KeyWindow) {
        let session = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak window] in
            guard let self = self, let window = window, self.generation == session, self.keyMonitor != nil,
                  !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    /// Power-off over the live stream; `done` once black
    /// Window stays until `hide`, which then closes it at once
    func powerOff(done: @escaping () -> Void) {
        guard let window = window, window.isVisible else { return done() }
        // Pending power-on steps (HUD, hint, pointer) become no-ops
        // No key monitor: a late full-screen entry cannot power on
        generation += 1
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        cursorSuppressed = true
        cursorLayer.isHidden = true
        noticeBox.removeAllAnimations()
        noticeBox.opacity = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hud.animator().alphaValue = 0
        }
        let animate = power.powerOff(effect: shownEffect)
        reportShown()
        guard animate else { return done() }
        view.layoutSubtreeIfNeeded()
        if shownEffect == .tiles { wave.powerOff(live: true) }
        poweredOffAt = CACurrentMediaTime() + duration(on: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration(on: false), execute: done)
    }

    /// false once powered off: nothing to hold for a relink
    var isPoweredOn: Bool {
        power.on
    }

    func hide() {
        held?.cancel()
        held = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        hudTimer?.invalidate()
        hudTimer = nil
        cursorLayer.isHidden = true
        if forcedHUD { hud.isHidden = true }
        forcedHUD = false
        hintLayer.removeAllAnimations()
        hintLayer.opacity = 0
        noticeBox.removeAllAnimations()
        noticeBox.opacity = 0
        pendingNotice = nil
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if opening {
            opening = false
            generation += 1
            return panelMode.restore()
        }
        guard let window = window else { return }
        generation += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hud.animator().alphaValue = 0
        }
        let animate = power.powerOff(effect: shownEffect)
        reportShown()
        // Sender's power-off cut short by its end: plays out
        let playing = poweredOffAt - CACurrentMediaTime()
        guard animate || playing > 0 else { return close(window) }
        if animate {
            view.layoutSubtreeIfNeeded()
            if shownEffect == .tiles { wave.powerOff() }
        } else if shownEffect == .tiles {
            // Live redraws stop with the session's resources
            wave.closeOverFarewell(for: playing)
        }
        let work = DispatchWorkItem { [weak self] in self?.close(window) }
        closing = (window, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? duration(on: false) : playing), execute: work)
    }

    private func duration(on: Bool) -> CFTimeInterval {
        switch shownEffect {
        case .tiles: return on ? TileWave.onDuration : TileWave.offDuration
        case .none: return 0
        }
    }

    /// Plays the session's power-on effect
    /// Then the HUD and, in a Space, the hint appear
    private func powerOn() {
        guard keyMonitor != nil, power.powerOn() else { return }
        reportShown()
        view.layoutSubtreeIfNeeded()
        if shownEffect == .tiles { wave.powerOn() }
        let session = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration(on: true)) { [weak self] in
            guard let self = self, self.generation == session else { return }
            self.cursorSuppressed = false
            self.placeCursor()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self.hud.animator().alphaValue = 1
            }
            if self.window?.styleMask.contains(.fullScreen) == true { self.showHint() }
            if let notice = self.pendingNotice {
                self.pendingNotice = nil
                self.showNotice(notice.title, detail: notice.detail)
            }
        }
    }

    private func close(_ window: KeyWindow) {
        if closing?.window === window { closing = nil }
        // Any effect: a waiting picture's redraws stop too
        wave.finish()
        // Closing a full-screen window exits its Space via system transition
        // Closed either way: a window mid-slide must not come back
        let fullScreen = window.styleMask.contains(.fullScreen)
        if !fullScreen { window.orderOut(nil) }
        window.close()
        if !windowed { NSApp.presentationOptions = [] }
        // After the Space's slide: a mode switch mid-slide stutters
        let restore = DispatchWorkItem { [weak self] in
            self?.restoreMode = nil
            self?.panelMode.restore()
        }
        restoreMode = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + (fullScreen ? 1 : 0), execute: restore)
    }

    /// New session during a power-off: that window closes at once
    private func closeNow() {
        guard let pending = closing else { return }
        pending.work.cancel()
        close(pending.window)
    }

    /// `screen`: without it AppKit moves the window to the main one
    private func makeWindow(_ style: Style, frame: NSRect, on screen: NSScreen?) -> KeyWindow {
        observers.forEach(NotificationCenter.default.removeObserver)
        let workspace = NSWorkspace.shared.notificationCenter
        if let old = wakeObserver { workspace.removeObserver(old) }
        // Once more a second later: activation may lag the screens
        wakeObserver = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.claimFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.claimFocus() }
        }
        window?.contentView = nil
        // This initializer takes the rect from the screen's origin
        let origin = screen?.frame.origin ?? .zero
        let local = NSRect(x: frame.minX - origin.x, y: frame.minY - origin.y, width: frame.width, height: frame.height)
        let window = KeyWindow(contentRect: local, styleMask: style.mask, backing: .buffered, defer: false, screen: screen)
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
        view.pointer = windowed ? nil : StreamWindow.localPointer
        window.contentView = container
        window.invalidateCursorRects(for: view)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window = window else { return }
                self?.onVisibilityChange?(window.occlusionState.contains(.visible))
                self?.reportShown()
            },
            // Key once active: the ring applies, hidden till moved
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard self?.windowed == false else { return }
                NSCursor.setHiddenUntilMouseMoves(true)
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self = self, let window = window else { return }
                // Ended mid-slide: the window was hidden before full screen
                guard self.window === window, self.keyMonitor != nil else { return window.close() }
                // The Space switch shows the pointer again
                NSCursor.setHiddenUntilMouseMoves(true)
                self.powerOn()
            },
        ]
        self.window = window
        return window
    }

    private func reportShown() {
        onShownChange?(power.on && window?.occlusionState.contains(.visible) == true)
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
        onHUDToggle?(!hud.isHidden)
    }

    // MARK: - Hint

    /// How to leave the stream's Space, shown briefly after opening
    private func showHint() {
        hintText.string = L10n.t("Control + ← → switches to \(ComputerName.current)'s desktop · right-click for the menu",
                                 "Control + ← →로 \(ComputerName.current) 데스크톱과 전환 · 우클릭으로 메뉴")
        placeHint()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.85, 1]
        fade.duration = 3.5
        hintLayer.add(fade, forKey: "hint")
    }

    /// Bottom centre for a few seconds, above the hint
    /// Ignores clicks; the picture stays usable
    func showNotice(_ title: String, detail: String?) {
        // Shown once the picture is up: the sender sends it once
        guard power.on else {
            pendingNotice = (title, detail)
            return
        }
        setNotice(title, detail: detail)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.06, 0.88, 1]
        fade.duration = 4.5
        noticeBox.add(fade, forKey: "notice")
    }

    /// Link lost: grey breathing picture and a lasting notice
    /// The picture stays readable; this is no freeze
    func showWaiting(detail: String?) {
        guard power.on, !wave.isWaiting else { return }
        wave.wait(motion: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        setNotice(L10n.t("Reconnecting", "다시 연결하는 중"), detail: detail)
        fadeNotice(to: 1)
    }

    /// Link back: colour returns centre-out; the notice goes
    func endWaiting() {
        guard wave.isWaiting else { return }
        wave.revive(motion: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        fadeNotice(to: 0)
    }

    private func fadeNotice(to opacity: Float) {
        noticeBox.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = noticeBox.presentation()?.opacity ?? noticeBox.opacity
        fade.toValue = opacity
        fade.duration = 0.25
        noticeBox.opacity = opacity
        noticeBox.add(fade, forKey: "notice")
    }

    private func setNotice(_ title: String, detail: String?) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .paragraphStyle: centred,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.97, alpha: 1),
        ])
        if let detail = detail {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: centred,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.72, alpha: 1),
            ]))
        }
        noticeText.string = text
        noticeSize = text.boundingRect(with: CGSize(width: 640, height: 200), options: [.usesLineFragmentOrigin]).size
        placeNotice()
    }

    private var noticeSize = CGSize.zero
    private var pendingNotice: (title: String, detail: String?)?

    private func placeNotice() {
        let pad = CGSize(width: 24, height: 12)
        let text = CGSize(width: ceil(noticeSize.width) + 2, height: ceil(noticeSize.height) + 2)
        let box = CGSize(width: text.width + 2 * pad.width, height: text.height + 2 * pad.height)
        noticeBox.frame = CGRect(x: view.bounds.midX - box.width / 2, y: 124, width: box.width, height: box.height)
        noticeText.frame = CGRect(origin: CGPoint(x: pad.width, y: pad.height), size: text)
    }

    private func placeHint() {
        let pad = CGSize(width: 22, height: 11)
        let measured = ((hintText.string as? String ?? "") as NSString).size(withAttributes: [.font: StreamWindow.hintFont])
        let text = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height))
        let box = CGSize(width: text.width + 2 * pad.width, height: text.height + 2 * pad.height)
        hintLayer.frame = CGRect(x: view.bounds.midX - box.width / 2, y: 64, width: box.width, height: box.height)
        hintText.frame = CGRect(origin: CGPoint(x: pad.width, y: pad.height), size: text)
    }

    // MARK: - Cursor

    func setCursor(x: Float, y: Float, visible: Bool) {
        cursorNormalized = (x, y, visible)
        placeCursor()
    }

    func setCursorImage(_ image: CursorImage) {
        cursorImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = NSImage(data: image.png)
        let w = max(1, CGFloat(image.width)), h = max(1, CGFloat(image.height))
        cursorLayer.anchorPoint = CGPoint(x: CGFloat(image.hotX) / w, y: 1 - CGFloat(image.hotY) / h)
        CATransaction.commit()
        placeCursor()
    }

    /// The stream in view points
    /// Placed as the renderer does: pixels, y down, then flipped
    private var videoRect: CGRect {
        let scale = window?.backingScaleFactor ?? 1
        let w = view.bounds.width * scale, h = view.bounds.height * scale, inset = min(h, notchInset * scale)
        let r = RenderGeometry.aspectFit(content: contentPixels, in: CGRect(x: 0, y: inset, width: w, height: h - inset))
        return CGRect(x: r.minX / scale, y: (h - r.maxY) / scale, width: r.width / scale, height: r.height / scale)
    }

    /// Points of the view beside the camera notch
    /// The stream sits below them
    /// A full-screen Space already ends there
    private var notchInset: CGFloat {
        guard #available(macOS 12, *), let window = window, let screen = window.screen, screen.safeAreaInsets.top > 0 else { return 0 }
        return max(0, min(window.frame.maxY, screen.frame.maxY) - (screen.frame.maxY - screen.safeAreaInsets.top))
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
        cursorLayer.isHidden = !cursorNormalized.visible || cursorSuppressed
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
