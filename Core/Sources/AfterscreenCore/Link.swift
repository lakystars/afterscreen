import Foundation
import IOKit
import SystemConfiguration

public struct InterfaceFacts: Equatable {
    public var name: String
    /// A Thunderbolt IP interface, or a bridge with one as a member
    public var isThunderbolt: Bool
    public var isUSBNCM: Bool
    public var isWiFi: Bool
    /// SystemConfiguration type Ethernet; Thunderbolt and USB networking report it too
    public var isEthernet: Bool
    public var isLoopback: Bool

    public init(name: String, isThunderbolt: Bool, isUSBNCM: Bool, isWiFi: Bool, isEthernet: Bool, isLoopback: Bool) {
        self.name = name
        self.isThunderbolt = isThunderbolt
        self.isUSBNCM = isUSBNCM
        self.isWiFi = isWiFi
        self.isEthernet = isEthernet
        self.isLoopback = isLoopback
    }
}

public enum LinkClassifier {
    public static func classify(_ f: InterfaceFacts) -> LinkKind {
        if f.isLoopback { return .loopback }
        if f.isThunderbolt { return .thunderbolt }
        if f.isUSBNCM { return .usb }
        if f.isWiFi { return .wifi }
        if f.isEthernet { return .ethernet }
        return .unsupported
    }

    public static func facts(for name: String) -> InterfaceFacts {
        let chain = ioClassChain(bsdName: name)
        let isThunderboltIP: (String) -> Bool = { ioClassChain(bsdName: $0).contains { $0.contains("ThunderboltIP") } }
        var thunderbolt = chain.contains { $0.contains("ThunderboltIP") }
        if !thunderbolt, name.hasPrefix("bridge"), let output = run("/sbin/ifconfig", [name]) {
            thunderbolt = bridgeMembers(ifconfigOutput: output).contains(where: isThunderboltIP)
        }
        return InterfaceFacts(name: name,
                              isThunderbolt: thunderbolt,
                              isUSBNCM: chain.contains { $0.contains("NCM") },
                              isWiFi: chain.contains { $0.contains("80211") || $0.contains("WLAN") },
                              isEthernet: isEthernetType(name),
                              isLoopback: name.hasPrefix("lo"))
    }

    /// Wired Ethernet per SystemConfiguration; VM bridges and tunnels are not listed as Ethernet
    static func isEthernetType(_ name: String) -> Bool {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return all.contains {
            (SCNetworkInterfaceGetBSDName($0) as String?) == name
                && (SCNetworkInterfaceGetInterfaceType($0) as String?) == (kSCNetworkInterfaceTypeEthernet as String)
        }
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
