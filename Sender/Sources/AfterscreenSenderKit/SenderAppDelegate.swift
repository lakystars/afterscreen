import AppKit
import Combine
import AfterscreenCore
import SwiftUI

/// Status button changes, applied only when they differ: each assignment lays out the item again,
/// and the popover anchored to it closes the menu it has open
enum StatusButton {
    @discardableResult
    static func show(_ button: NSButton, image: NSImage, title: String) -> Bool {
        guard button.image !== image || button.title != title else { return false }
        if button.image !== image { button.image = image }
        if button.title != title { button.title = title }
        return true
    }
}

/// Gives an open popover its focus back after the displays change. A virtual display coming or going
/// moves focus off the menu bar app, and the next click inside only re-activates it, closing the menu it opened.
/// Plain deactivation is left alone: that is the user switching apps
final class PopoverFocusKeeper {
    var isShown: () -> Bool = { false }
    var isFocused: () -> Bool = { true }
    var restore: () -> Void = {}
    /// Display changes settle over a few hundred milliseconds, and focus moves late in them
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

    /// Also called as a stream starts: its virtual display is the change
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
    /// Clicks in other apps while the popover is open
    private var outsideClicks: Any?
    private let model = AppModel()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let focusKeeper = PopoverFocusKeeper()
    private var wasStreaming = false

    public override init() {}

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
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model) { [weak self] in self?.showSettings() })
        // Published fires before the change is stored, so the title is read on the next run loop turn
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
    }

    /// The icon and the widest stats title: M is wider than G, and digits wider than "."
    private lazy var statsWidth: CGFloat = {
        let font = statusItem.button?.font ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = ceil(("60fps · 888M" as NSString).size(withAttributes: [.font: font]).width)
        return ceil(StatusIcon.image(link: nil).size.width) + 4 + text + 12
    }()

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.screenRecordingGranted = CGPreflightScreenCaptureAccess()
            model.refreshLinks()
            // A menu bar app is not active on its own: the first click inside would activate it and dismiss
            // the menu it opened, and a transient popover closes on deactivation it would never see
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClicks { NSEvent.removeMonitor(monitor) }
        outsideClicks = nil
    }

    private func showSettings() {
        popover.performClose(nil)
        // Rebuilt on each open: size labels follow the receiver last seen
        let content = NSHostingController(rootView: SettingsView(settings: model.settings, panelPoints: model.panelPoints))
        if let window = settingsWindow {
            window.contentViewController = content
        } else {
            let window = NSWindow(contentViewController: content)
            window.title = L10n.t("Afterscreen Settings", "Afterscreen 설정")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Automation hook: connect to, or test, the first receiver whose name contains `match`
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
