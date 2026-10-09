import Darwin
import AfterscreenCore

public struct LocalInterface: Equatable {
    public var name: String
    public var ip: String
    public var netmask: String
    public var kind: LinkKind
}

public struct Route: Equatable {
    public var interface: String
    public var address: String
    public var kind: LinkKind
}

/// Orders (local interface, receiver address) pairs: Thunderbolt, USB, Ethernet, then Wi-Fi
public enum RoutePlanner {
    private static let priority: [LinkKind] = [.thunderbolt, .usb, .ethernet, .wifi]

    public static func plan(local: [LocalInterface], remote: [String]) -> [Route] {
        let remoteV4 = remote.filter { ipv4($0) != nil }
        if remoteV4.contains(where: { r in local.contains { $0.ip == r } }) {
            return [Route(interface: "lo0", address: "127.0.0.1", kind: .loopback)]
        }
        var routes: [Route] = []
        for kind in priority {
            for iface in local where iface.kind == kind {
                guard let ip = ipv4(iface.ip), let mask = ipv4(iface.netmask) else { continue }
                if let match = remoteV4.first(where: { ipv4($0).map { $0 & mask == ip & mask } ?? false }) {
                    routes.append(Route(interface: iface.name, address: match, kind: kind))
                }
            }
        }
        return routes
    }

    /// Up IPv4 interfaces with their link kind
    public static func currentInterfaces() -> [LocalInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [LocalInterface] = []
        var cursor = list
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask,
                  (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let kind = LinkClassifier.classify(LinkClassifier.facts(for: name))
            result.append(LocalInterface(name: name, ip: string(addr), netmask: string(mask), kind: kind))
        }
        return result
    }

    private static func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var sin = sockaddr_in()
        memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    static func ipv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}
