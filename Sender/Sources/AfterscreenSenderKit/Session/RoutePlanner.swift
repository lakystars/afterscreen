import Darwin
import Foundation
import AfterscreenCore
import dnssd

public struct LocalInterface: Equatable {
    public var name: String
    /// IPv4; empty on an IPv6-only interface
    public var ip: String
    public var netmask: String
    public var kind: LinkKind
    /// IPv6 addresses, unscoped
    public var v6: [String] = []
}

/// Receiver address; `via`: answering local interface if mDNS reported it
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

/// Orders (interface, receiver address) pairs: Thunderbolt, USB, Ethernet, Wi-Fi
public enum RoutePlanner {
    private static let priority: [LinkKind] = [.thunderbolt, .usb, .ethernet, .wifi]

    /// Address that answered on a known interface routes only there
    /// Link-local subnets repeat on every cable
    /// IPv4 first; IPv6 where mDNS answered on that interface
    /// A Thunderbolt Bridge with IPv4 off still routes
    public static func plan(local: [LocalInterface], remote: [RemoteAddress]) -> [Route] {
        let remoteV4 = remote.filter { ipv4($0.ip) != nil }
        let remoteV6 = remote.filter { ipv4($0.ip) == nil }
        let own = { (r: RemoteAddress) in local.contains { !$0.ip.isEmpty && $0.ip == r.ip || $0.v6.contains(unscoped(r.ip)) } }
        if remote.contains(where: own) {
            return [Route(interface: Interfaces.loopbackName ?? "", address: "127.0.0.1", kind: .loopback)]
        }
        var routes: [Route] = []
        for kind in priority {
            for iface in local where iface.kind == kind {
                if let ip = ipv4(iface.ip), let mask = ipv4(iface.netmask), let match = remoteV4.first(where: { r in
                    r.via.map { $0 == iface.name } ?? (ipv4(r.ip).map { $0 & mask == ip & mask } ?? false)
                }) {
                    routes.append(Route(interface: iface.name, address: match.ip, kind: kind))
                } else if let match = remoteV6.first(where: { $0.via == iface.name }) {
                    routes.append(Route(interface: iface.name, address: match.ip, kind: kind))
                }
            }
        }
        return routes
    }

    /// "fe80::1%bridge0" → "fe80::1"
    static func unscoped(_ ip: String) -> String { ip.split(separator: "%").first.map(String.init) ?? ip }

    /// Links in route order, each once
    public static func kinds(_ routes: [Route]) -> [LinkKind] {
        routes.reduce(into: []) { if !$0.contains($1.kind) { $0.append($1.kind) } }
    }

    /// Automatic link mid-session: the faster link to move to
    /// nil: the current link is already the fastest
    public static func upgrade(from current: LinkKind?, available: [LinkKind]) -> LinkKind? {
        guard let current = current, let now = priority.firstIndex(of: current),
              let fastest = available.first, let rank = priority.firstIndex(of: fastest), rank < now else { return nil }
        return fastest
    }

    /// Routes over the chosen link
    /// nil or link gone: all routes, fastest first
    public static func select(_ routes: [Route], prefer: LinkKind?) -> (routes: [Route], fellBack: Bool) {
        guard let prefer = prefer else { return (routes, false) }
        let chosen = routes.filter { $0.kind == prefer }
        return chosen.isEmpty ? (routes, true) : (chosen, false)
    }

    /// Other links' routes, tried when the chosen link's fail
    /// Empty when `select` already returned every route
    public static func fallback(_ routes: [Route], prefer: LinkKind?) -> [Route] {
        guard let prefer = prefer, routes.contains(where: { $0.kind == prefer }) else { return [] }
        return routes.filter { $0.kind != prefer }
    }

    /// Routes to a receiver over every currently answering link
    /// Runs off the calling thread
    public static func routes(to receiver: DiscoveredReceiver, wait: TimeInterval = 0.5, completion: @escaping ([Route]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let local = currentInterfaces().filter { $0.kind != .unsupported }
            lookup(host: receiver.host, on: local.map(\.name), wait: wait) { found in
                completion(plan(local: local, remote: found + receiver.addresses.map { RemoteAddress($0) }))
            }
        }
    }

    /// Link kind per interface name, cached 30 s
    /// Detecting a Thunderbolt bridge runs ifconfig
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

    /// mDNS host's addresses on each of `interfaces`, IPv4 and IPv6
    /// Link-local IPv6 comes scoped: "fe80::1%bridge0"
    /// Gathered for `wait` seconds
    /// Bonjour resolve reports one interface
    /// All-interface lookup stops at the first answer, often Wi-Fi
    /// So each cable is queried separately
    public static func lookup(host: String, on interfaces: [String], wait: TimeInterval = 0.5,
                              completion: @escaping ([RemoteAddress]) -> Void) {
        final class Found { var addresses: [RemoteAddress] = [] }
        let found = Found()
        let context = Unmanaged.passRetained(found).toOpaque()
        let queue = DispatchQueue(label: "afterscreen.lookup")
        let services: [DNSServiceRef] = host.isEmpty ? [] : interfaces.compactMap { name in
            var ref: DNSServiceRef?
            let both = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
            let error = DNSServiceGetAddrInfo(&ref, 0, if_nametoindex(name), both, host, { _, flags, index, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let address = address, let context = context else { return }
            var ip = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &ip, socklen_t(ip.count), nil, 0, NI_NUMERICHOST) == 0,
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

    /// Up interfaces with IPv4 or IPv6, and their link kind
    public static func currentInterfaces() -> [LocalInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var byName: [String: LocalInterface] = [:]
        var order: [String] = []
        var ethernet: Set<String>?
        var cursor = list
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if byName[name] == nil {
                let kind = kind(of: name) {
                    if ethernet == nil { ethernet = LinkClassifier.ethernetNames() }
                    return ethernet!
                }
                byName[name] = LocalInterface(name: name, ip: "", netmask: "", kind: kind)
                order.append(name)
            }
            if family == AF_INET, let mask = ifa.pointee.ifa_netmask {
                byName[name]?.ip = string(addr)
                byName[name]?.netmask = string(mask)
            } else if family == AF_INET6 {
                byName[name]?.v6.append(unscoped(string(addr)))
            }
        }
        // IPv6 alone: configured links only; awdl0, utun stay out
        let configured = { (name: String) in
            if ethernet == nil { ethernet = LinkClassifier.ethernetNames() }
            return ethernet!.contains(name) || LinkClassifier.wifiNames.contains(name) || Interfaces.isBridge(name)
        }
        return order.compactMap { byName[$0] }.filter { !$0.ip.isEmpty || configured($0.name) }
    }

    /// Numeric host of an IPv4 or IPv6 socket address
    /// IPv4 by copy: netmasks arrive with a trimmed sa_len
    private static func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if Int32(sa.pointee.sa_family) == AF_INET6 {
            guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
            return String(cString: buffer)
        }
        var sin = sockaddr_in()
        memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
        inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    static func ipv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}
