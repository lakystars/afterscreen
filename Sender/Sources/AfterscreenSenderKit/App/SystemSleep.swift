import Foundation
import IOKit.pwr_mgt

/// System sleep notices; sleep waits for `onSleep`'s answer
/// macOS sleeps anyway after 30 s
final class SystemSleep {
    /// Main queue; the argument lets sleep proceed
    var onSleep: ((@escaping () -> Void) -> Void)?
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // iokit_common_msg values: Swift skips those macros
    private static let canSleep: UInt32 = 0xE000_0270
    private static let willSleep: UInt32 = 0xE000_0280

    init() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(refcon, &port, { refcon, _, type, argument in
            guard let refcon = refcon else { return }
            Unmanaged<SystemSleep>.fromOpaque(refcon).takeUnretainedValue().handle(type, id: Int(bitPattern: argument))
        }, &notifier)
        guard root != 0, let port = port else { return }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    deinit {
        guard root != 0 else { return }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(root)
        if let port = port { IONotificationPortDestroy(port) }
    }

    private func handle(_ type: UInt32, id: Int) {
        switch type {
        case SystemSleep.canSleep:
            // Idle sleep: the session's activity already holds it off
            IOAllowPowerChange(root, id)
        case SystemSleep.willSleep:
            var answered = false
            let allow = { [root] in
                guard !answered else { return }
                answered = true
                IOAllowPowerChange(root, id)
            }
            guard let onSleep = onSleep else { return allow() }
            onSleep(allow)
        default:
            break
        }
    }
}
