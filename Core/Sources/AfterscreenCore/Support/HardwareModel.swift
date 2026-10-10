import Darwin

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
