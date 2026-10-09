import Foundation
import IOKit

public struct InterfaceFacts: Equatable {
    public var name: String
    public var isBridgeWithThunderbolt: Bool
    public var isUSBNCM: Bool
    public var isWiFi: Bool
    public var isLoopback: Bool

    public init(name: String, isBridgeWithThunderbolt: Bool, isUSBNCM: Bool, isWiFi: Bool, isLoopback: Bool) {
        self.name = name
        self.isBridgeWithThunderbolt = isBridgeWithThunderbolt
        self.isUSBNCM = isUSBNCM
        self.isWiFi = isWiFi
        self.isLoopback = isLoopback
    }
}

public enum LinkClassifier {
    public static func classify(_ f: InterfaceFacts) -> LinkKind {
        if f.isLoopback { return .loopback }
        if f.isBridgeWithThunderbolt { return .thunderbolt }
        if f.isUSBNCM { return .usb }
        if f.isWiFi { return .wifi }
        return .unsupported
    }

    public static func facts(for name: String) -> InterfaceFacts {
        let chain = ioClassChain(bsdName: name)
        var tbBridge = false
        if name.hasPrefix("bridge"), let output = run("/sbin/ifconfig", [name]) {
            tbBridge = bridgeMembers(ifconfigOutput: output).contains { member in
                ioClassChain(bsdName: member).contains { $0.contains("ThunderboltIP") }
            }
        }
        return InterfaceFacts(name: name,
                              isBridgeWithThunderbolt: tbBridge,
                              isUSBNCM: chain.contains { $0.contains("NCM") },
                              isWiFi: chain.contains { $0.contains("80211") || $0.contains("WLAN") },
                              isLoopback: name.hasPrefix("lo"))
    }

    public static func bridgeMembers(ifconfigOutput: String) -> [String] {
        ifconfigOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("member: ") else { return nil }
            return trimmed.dropFirst(8).split(separator: " ").first.map(String.init)
        }
    }

    /// IOKit class names from the interface up through its parents
    public static func ioClassChain(bsdName: String) -> [String] {
        guard let matching = IOBSDNameMatching(0, 0, bsdName) else { return [] }
        var entry = IOServiceGetMatchingService(0, matching)
        var names: [String] = []
        var depth = 0
        while entry != 0 && depth < 8 {
            var buffer = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &buffer)
            names.append(String(cString: buffer))
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = status == KERN_SUCCESS ? parent : 0
            depth += 1
        }
        if entry != 0 { IOObjectRelease(entry) }
        return names
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
