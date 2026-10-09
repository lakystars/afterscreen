import AppKit
import Combine
import SwiftUI

/// Status item with a SwiftUI popover
public final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var cancellables: Set<AnyCancellable> = []

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = model.statusTitle
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Automation hook: connect to the first receiver whose name contains `match`
    public func autoConnect(match: String) {
        model.$receivers.first { list in list.contains { $0.name.localizedCaseInsensitiveContains(match) || match == "*" } }
            .sink { [weak self] list in
                if let r = list.first(where: { $0.name.localizedCaseInsensitiveContains(match) || match == "*" }) {
                    self?.model.connect(r)
                }
            }
            .store(in: &cancellables)
    }
}
