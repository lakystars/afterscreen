import AppKit
import AfterscreenSenderKit

let app = NSApplication.shared
let delegate = SenderAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// --connect <name|*> connects to the first matching receiver once discovered
if let i = CommandLine.arguments.firstIndex(of: "--connect"), i + 1 < CommandLine.arguments.count {
    let match = CommandLine.arguments[i + 1]
    DispatchQueue.main.async { delegate.autoConnect(match: match) }
}
app.run()
