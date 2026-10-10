import Darwin
import Foundation
import AfterscreenCore
import dnssd

public struct LocalInterface: Equatable {
    public var name: String
    public var ip: String
    public var netmask: String
    public var kind: LinkKind
}

/// A receiver address and, when mDNS reported it, the local interface it answered on
public struct RemoteAddress: Equatable {
    public var ip: String
    public var via: String?

    public init(_ ip: String, via: String? = nil) {
        self.ip = ip
        self.via = via
    }
}

public struct Route: Equatable {
    public var interface: String
    public var address: String
    public var kind: LinkKind
}

/// Orders (local interface, receiver address) pairs: Thunderbolt, USB, Ethernet, then Wi-Fi
public enum RoutePlanner {
    private static let priority: [LinkKind] = [.thunderbolt, .usb, .ethernet, .wifi]

    /// An address that answered on a known interface only routes there: link-local subnets repeat on every cable
    public static func plan(local: [LocalInterface], remote: [RemoteAddress]) -> [Route] {
        let remoteV4 = remote.filter { ipv4($0.ip) != nil }
        if remoteV4.contains(where: { r in local.contains { $0.ip == r.ip } }) {
            return [Route(interface: "lo0", address: "127.0.0.1", kind: .loopback)]
        }
        var routes: [Route] = []
        for kind in priority {
            for iface in local where iface.kind == kind {
                guard let ip = ipv4(iface.ip), let mask = ipv4(iface.netmask) else { continue }
                let match = remoteV4.first { r in
                    r.via.map { $0 == iface.name } ?? (ipv4(r.ip).map { $0 & mask == ip & mask } ?? false)
                }
                if let match = match { routes.append(Route(interface: iface.name, address: match.ip, kind: kind)) }
            }
        }
        return routes
    }

    /// Links in route order, each once
    public static func kinds(_ routes: [Route]) -> [LinkKind] {
        routes.reduce(into: []) { if !$0.contains($1.kind) { $0.append($1.kind) } }
    }

    /// Routes over the chosen link; all routes (the fastest first) when nil or when that link is gone
    public static func select(_ routes: [Route], prefer: LinkKind?) -> (routes: [Route], fellBack: Bool) {
        guard let prefer = prefer else { return (routes, false) }
        let chosen = routes.filter { $0.kind == prefer }
        return chosen.isEmpty ? (routes, true) : (chosen, false)
    }

    /// Routes to a receiver over every link that answers now; works off the calling thread
    public static func routes(to receiver: DiscoveredReceiver, completion: @escaping ([Route]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let local = currentInterfaces().filter { $0.kind != .unsupported }
            lookup(host: receiver.host, on: local.map(\.name)) { found in
                completion(plan(local: local, remote: found + receiver.addresses.map { RemoteAddress($0) }))
            }
        }
    }

    /// Link kind per interface name, for 30 s: telling a Thunderbolt bridge apart runs ifconfig
    private static var kinds: (until: TimeInterval, byName: [String: LinkKind]) = (0, [:])
    private static let kindsLock = NSLock()

    static func kind(of name: String, ethernet: () -> Set<String>) -> LinkKind {
        let now = ProcessInfo.processInfo.systemUptime
        kindsLock.lock()
        if now > kinds.until { kinds = (now + 30, [:]) }
        let known = kinds.byName[name]
        kindsLock.unlock()
        if let known = known { return known }
        let kind = LinkClassifier.classify(LinkClassifier.facts(for: name, ethernet: ethernet()))
        kindsLock.lock()
        kinds.byName[name] = kind
        kindsLock.unlock()
        return kind
    }

    /// IPv4 addresses of an mDNS host on each of `interfaces`, gathered for `wait` seconds.
    /// A Bonjour resolve reports one interface, and a lookup on all interfaces stops at the first
    /// that answers (often Wi-Fi), so each cable is asked on its own
    public static func lookup(host: String, on interfaces: [String], wait: TimeInterval = 0.5,
                              completion: @escaping ([RemoteAddress]) -> Void) {
        final class Found { var addresses: [RemoteAddress] = [] }
        let found = Found()
        let context = Unmanaged.passRetained(found).toOpaque()
        let queue = DispatchQueue(label: "afterscreen.lookup")
        let services: [DNSServiceRef] = host.isEmpty ? [] : interfaces.compactMap { name in
            var ref: DNSServiceRef?
            let error = DNSServiceGetAddrInfo(&ref, 0, if_nametoindex(name), DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, flags, index, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let address = address, let context = context else { return }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &ip, socklen_t(ip.count), nil, 0, NI_NUMERICHOST) == 0,
                  if_indextoname(index, &name) != nil else { return }
            Unmanaged<Found>.fromOpaque(context).takeUnretainedValue().addresses.append(RemoteAddress(String(cString: ip), via: String(cString: name)))
            }, context)
            guard error == kDNSServiceErr_NoError, let service = ref else { return nil }
            DNSServiceSetDispatchQueue(service, queue)
            return service
        }
        queue.asyncAfter(deadline: .now() + (services.isEmpty ? 0 : wait)) {
            services.forEach(DNSServiceRefDeallocate)
            Unmanaged<Found>.fromOpaque(context).release()
            completion(found.addresses)
        }
    }

    /// Up IPv4 interfaces with their link kind
    public static func currentInterfaces() -> [LocalInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [LocalInterface] = []
        var ethernet: Set<String>?
        var cursor = list
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask,
                  (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let kind = kind(of: name) {
                if ethernet == nil { ethernet = LinkClassifier.ethernetNames() }
                return ethernet!
            }
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
