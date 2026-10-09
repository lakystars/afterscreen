import AppKit
import AfterscreenReceiverKit

let app = NSApplication.shared
let delegate = ReceiverAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
