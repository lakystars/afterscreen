import AppKit
import Combine
import AfterscreenCore
import SwiftUI

/// Status button updates, applied only when values differ
/// Each assignment re-lays out the item
/// Anchored popover then closes its open menu
enum StatusButton {
    @discardableResult
    static func show(_ button: NSButton, image: NSImage, title: String) -> Bool {
        guard button.image !== image || button.title != title else { return false }
        if button.image !== image { button.image = image }
        if button.title != title { button.title = title }
        return true
    }
}

/// Why the app quits, from the Apple Event being handled
/// No quit event: the Quit button
enum QuitCause: Equatable {
    /// `other`: log out, a script or another app
    case user, shutDown, restart, other

    init(event: NSAppleEventDescriptor?) {
        guard let event = event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else {
            self = .user
            return
        }
        switch event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue {
        case kAEShutDown?, kAEShowShutdownDialog?: self = .shutDown
        case kAERestart?, kAEShowRestartDialog?: self = .restart
        default: self = .other
        }
    }

    /// The receiver follows the end setting; a restart comes back
    var powersReceiver: Bool { self == .user || self == .shutDown }

    static var current: QuitCause { QuitCause(event: NSAppleEventManager.shared().currentAppleEvent) }
}

/// Restores open popover focus after display changes
/// Virtual display add/remove moves focus off the app
/// Next click then only reactivates it, closing its open menu
/// Plain deactivation ignored: user switching apps
final class PopoverFocusKeeper {
    var isShown: () -> Bool = { false }
    var isFocused: () -> Bool = { true }
    var restore: () -> Void = {}
    /// Display changes settle over a few hundred ms
    /// Focus moves late in that window
    static let checks: [TimeInterval] = [0.1, 0.5, 1.0]
    private let center: NotificationCenter
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, check in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
         }) {
        self.center = center
        self.schedule = schedule
        observer = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            self?.displaysChanged()
        }
    }

    deinit {
        observer.map(center.removeObserver)
    }

    /// Also called at stream start: the virtual display appears
    func displaysChanged() {
        for delay in PopoverFocusKeeper.checks {
            schedule(delay) { [weak self] in
                guard let self = self, self.isShown(), !self.isFocused() else { return }
                self.restore()
            }
        }
    }
}

/// Status item with a SwiftUI popover
public final class SenderAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Paddings, arrow, popover frame and a bottom gap
    private static let popoverChrome: CGFloat = 64
    /// Clicks in other apps while the popover is open
    private var outsideClicks: Any?
    private let model = AppModel()
    private var cancellables: Set<AnyCancellable> = []
    private let focusKeeper = PopoverFocusKeeper()
    private var wasStreaming = false

    public override init() {}

    /// Quit while connected waits for the iMac's power-off
    /// Sound returns to this Mac as its screen turns black
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isActive else { return .terminateNow }
        // Async: a session that ends at once replies after terminateLater
        model.closeForQuit(powerReceiver: QuitCause.current.powersReceiver) {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.image = model.statusIcon
        statusItem.button?.title = model.statusTitle
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        focusKeeper.isShown = { [weak self] in self?.popover.isShown ?? false }
        focusKeeper.isFocused = { [weak self] in NSApp.isActive && self?.popover.contentViewController?.view.window?.isKeyWindow == true }
        focusKeeper.restore = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.popover.contentViewController?.view.window?.makeKey()
        }
        let content = NSHostingController(rootView: PopoverView(model: model))
        // Size known before showing; later changes keep the arrow anchored
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        // Published fires before the value is stored
        // Read the title on the next run loop turn
        model.$snapshot.map { _ in () }.merge(with: model.settings.$menuBarStats.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in
                guard let self = self else { return }
                if self.model.snapshot.isStreaming && !self.wasStreaming { self.focusKeeper.displaysChanged() }
                self.wasStreaming = self.model.snapshot.isStreaming
                guard let button = self.statusItem.button else { return }
                StatusButton.show(button, image: self.model.statusIcon, title: self.model.statusTitle)
                let length = self.model.settings.menuBarStats && self.model.snapshot.isStreaming ? self.statsWidth : NSStatusItem.variableLength
                if self.statusItem.length != length { self.statusItem.length = length }
            }.store(in: &cancellables)
        // Display changes while the popover stays open
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.fitPopover() }
            .store(in: &cancellables)
        // Code field in front while the iMac shows the code
        model.$pairingWith.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] name in
            if name != nil { self?.showPopover() }
        }.store(in: &cancellables)
    }

    /// Icon plus widest stats title
    /// M is wider than G; digits wider than "."
    private lazy var statsWidth: CGFloat = {
        let font = statusItem.button?.font ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = ceil(("60fps · 888M" as NSString).size(withAttributes: [.font: font]).width)
        return ceil(StatusIcon.image(link: nil, role: .sender).size.width) + 4 + text + 12
    }()

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.screenRecordingGranted = CGPreflightScreenCaptureAccess()
        model.refreshLinks()
        // Menu bar app does not activate on its own
        // Otherwise the first click activates it, dismissing its open menu
        // Transient popover needs activation to see deactivation and close
        NSApp.activate(ignoringOtherApps: true)
        fitPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    /// Room below the menu bar for the popover's content
    /// Measured from the status item; visibleFrame includes auto-hidden menu bars
    private func fitPopover() {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let top = statusItem.button?.window?.frame.minY ?? screen.visibleFrame.maxY
        model.popoverHeight = top - screen.visibleFrame.minY - SenderAppDelegate.popoverChrome
    }

    public func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClicks { NSEvent.removeMonitor(monitor) }
        outsideClicks = nil
        // Reopens on the first level
        model.showsSettings = false
    }

    /// Development: codes from a file, as if typed
    public func typePairingCodes(from path: String) {
        model.typePairingCodes(from: path)
    }

    /// Automation hook: connect or test first receiver containing `match`
    public func autoConnect(match: String, test: Bool = false) {
        let matches: (DiscoveredReceiver) -> Bool = { $0.name.localizedCaseInsensitiveContains(match) || match == "*" }
        model.$receivers.first { $0.contains(where: matches) }
            .sink { [weak self] list in
                guard let r = list.first(where: matches) else { return }
                test ? self?.model.runQualityTest(r) : self?.model.connect(r)
            }
            .store(in: &cancellables)
    }
}
