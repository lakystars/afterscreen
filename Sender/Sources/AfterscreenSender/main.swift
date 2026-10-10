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
// --link <thunderbolt|usb|ethernet|wifi|auto> sets the link, as the popover does
if let i = CommandLine.arguments.firstIndex(of: "--link"), i + 1 < CommandLine.arguments.count {
    SenderSettings().link = LinkKind(rawValue: CommandLine.arguments[i + 1])
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
