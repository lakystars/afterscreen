import AppKit
import AfterscreenSenderKit

let app = NSApplication.shared
let delegate = SenderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// --simulate-link <Mbps> paces the connection and treats it as Wi-Fi (hybrid path on loopback)
if let i = CommandLine.arguments.firstIndex(of: "--simulate-link"), i + 1 < CommandLine.arguments.count {
    SenderSession.simulatedLinkMbps = Double(CommandLine.arguments[i + 1])
}
// --connect <name|*> connects to the first matching receiver once discovered; --test <name|*> runs the quality test
for (flag, test) in [("--connect", false), ("--test", true)] {
    if let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count {
        let match = CommandLine.arguments[i + 1]
        DispatchQueue.main.async { delegate.autoConnect(match: match, test: test) }
    }
}
app.run()
