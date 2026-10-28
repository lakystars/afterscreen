import AppKit

/// Shut down through loginwindow, as the Apple menu does
/// macOS asks Automation consent once; only Settings asks
enum Shutdown {
    private static var loginwindow: NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow") }

    /// `ask`: macOS prompts if undecided, blocking until answered
    static func consent(ask: Bool) -> OSStatus {
        let target = loginwindow
        // aeDesc points into the descriptor: keep it alive
        return withExtendedLifetime(target) {
            guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(desc, kCoreEventClass, kAEShutDown, ask)
        }
    }

    /// Apps may ask to save and cancel it
    /// false without consent: no prompt nobody answers
    static func now() -> Bool {
        guard consent(ask: false) == noErr else { return false }
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEShutDown, targetDescriptor: loginwindow,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        return (try? event.sendEvent(options: [.noReply], timeout: 10)) != nil
    }
}
