import AppKit
import AfterscreenCore
import AfterscreenSenderKit

let app = NSApplication.shared
let delegate = SenderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// --simulate-link <Mbps>: paced connection treated as Wi-Fi
// For testing the hybrid path on loopback
if let i = CommandLine.arguments.firstIndex(of: "--simulate-link"), i + 1 < CommandLine.arguments.count {
    SenderSession.simulatedLinkMbps = Double(CommandLine.arguments[i + 1])
}
SenderSession.logStats = CommandLine.arguments.contains("--log-stats")
// --link <thunderbolt|usb|ethernet|wifi|auto>: this launch's link, not saved
if let i = CommandLine.arguments.firstIndex(of: "--link"), i + 1 < CommandLine.arguments.count {
    SenderSettings.launchLink = .some(LinkKind(rawValue: CommandLine.arguments[i + 1]))
}
// --pair-code-file <path>: codes written there are typed in
if let i = CommandLine.arguments.firstIndex(of: "--pair-code-file"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    DispatchQueue.main.async { delegate.typePairingCodes(from: path) }
}
// --connect <name|*>: first matching receiver, once discovered
// --test <name|*>: runs the quality test instead
for (flag, test) in [("--connect", false), ("--test", true)] {
    if let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count {
        let match = CommandLine.arguments[i + 1]
        DispatchQueue.main.async { delegate.autoConnect(match: match, test: test) }
    }
}
app.run()
