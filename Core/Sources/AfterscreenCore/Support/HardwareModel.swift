import Darwin
import SystemConfiguration

public enum HardwareModel {
    /// sysctl hw.model, e.g. "iMac18,3"
    public static var identifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// Sharing settings' computer name, read once
/// Shown for this Mac; peers get it in Hello, Welcome
public enum ComputerName {
    public static let current = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
}
