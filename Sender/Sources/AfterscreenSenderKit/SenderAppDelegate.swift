import AppKit
import Combine
import AfterscreenCore
import SwiftUI

/// Status item with a SwiftUI popover
public final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = model.statusTitle
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model) { [weak self] in self?.showSettings() })
        // Published fires before the change is stored, so the title is read on the next run loop turn
        model.$snapshot.map { _ in () }.merge(with: model.settings.$menuBarStats.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in
                guard let self = self else { return }
                self.statusItem.button?.title = self.model.statusTitle
            }.store(in: &cancellables)
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.screenRecordingGranted = CGPreflightScreenCaptureAccess()
            model.refreshLinks()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
