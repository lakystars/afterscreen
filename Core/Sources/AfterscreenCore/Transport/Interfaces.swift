import Darwin
import Foundation

/// Address formatting and local interface lookup for sockets
public enum Interfaces {
    /// MTU of interface `name`, from its link-layer address entry
    public static func mtu(_ name: String) -> Int? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name, ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            return Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
        }
        return nil
    }

    /// Each interface's name, kernel link type (e.g. IFT_BRIDGE) and flags
    private static func links() -> [(name: String, type: UInt8, flags: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var out: [(name: String, type: UInt8, flags: UInt32)] = []
        var cursor = list
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data else { continue }
            out.append((String(cString: ifa.pointee.ifa_name), data.assumingMemoryBound(to: if_data.self).pointee.ifi_type, ifa.pointee.ifa_flags))
        }
        return out
    }

    private static func link(_ name: String) -> (name: String, type: UInt8, flags: UInt32)? { links().first { $0.name == name } }

    /// First loopback interface, by flag
    public static var loopbackName: String? { links().first { $0.flags & UInt32(IFF_LOOPBACK) != 0 }?.name }

    /// By the kernel's link type, not the name
    public static func isBridge(_ name: String) -> Bool { link(name)?.type == UInt8(IFT_BRIDGE) }

    public static func isLoopback(_ name: String) -> Bool { (link(name)?.flags ?? 0) & UInt32(IFF_LOOPBACK) != 0 }

    /// Media status, as ifconfig's "status:" line
    /// false: cable out; nil: no media status, as on loopback
    public static func isActive(_ name: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var req = ifmediareq()
        withUnsafeMutableBytes(of: &req.ifm_name) { buf in
            name.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        // _IOWR('i', 56, struct ifmediareq): a macro Swift cannot import
        let request = UInt(0xC000_0000) | UInt(MemoryLayout<ifmediareq>.size & 0x1fff) << 16 | UInt(UInt8(ascii: "i")) << 8 | 56
        guard ioctl(fd, request, &req) == 0, req.ifm_status & IFM_AVALID != 0 else { return nil }
        return req.ifm_status & IFM_ACTIVE != 0
    }

    static func string(_ storage: sockaddr_storage) -> String? {
        var copy = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(storage.ss_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return ok == 0 ? String(cString: host) : nil
    }

    static func name(forLocalAddress storage: sockaddr_storage) -> String? {
        guard let local = string(storage) else { return nil }
        // IPv4-mapped IPv6 locals compare by their IPv4 part
        let wanted = local.hasPrefix("::ffff:") ? String(local.dropFirst(7)) : local
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var s = sockaddr_storage()
            withUnsafeMutableBytes(of: &s) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: addr, count: Int(addr.pointee.sa_len)))
            }
            if let candidate = string(s) {
                let bare = candidate.split(separator: "%").first.map(String.init) ?? candidate
                if bare == wanted.split(separator: "%").first.map(String.init) {
                    return String(cString: ifa.pointee.ifa_name)
                }
            }
        }
        return nil
    }

    /// Interface a peer's packets arrive on, not their target
    /// A host may send to a cable's address over Wi-Fi
    /// IPv6 link-local: the scope; IPv4: the ARP entry's interface
    /// nil when neither tells
    static func arrivalName(forPeer storage: sockaddr_storage) -> String? {
        var copy = storage
        switch Int32(storage.ss_family) {
        case AF_INET6:
            let sin6 = withUnsafeBytes(of: &copy) { $0.load(as: sockaddr_in6.self) }
            let b = sin6.sin6_addr.__u6_addr.__u6_addr8
            // IPv4-mapped: the IPv4 path
            if b.0 == 0, b.1 == 0, b.2 == 0, b.3 == 0, b.4 == 0, b.5 == 0, b.6 == 0, b.7 == 0, b.8 == 0, b.9 == 0, b.10 == 0xFF, b.11 == 0xFF {
                return arpName(in_addr(s_addr: UInt32(b.12) | UInt32(b.13) << 8 | UInt32(b.14) << 16 | UInt32(b.15) << 24))
            }
            return sin6.sin6_scope_id == 0 ? nil : indexName(sin6.sin6_scope_id)
        case AF_INET:
            return arpName(withUnsafeBytes(of: &copy) { $0.load(as: sockaddr_in.self) }.sin_addr)
        default:
            return nil
        }
    }

    /// Walks the kernel's ARP table for `ip`
    static func arpName(_ ip: in_addr) -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self).rtm_msglen)
                guard length > 0 else { return nil }
                let at = offset + MemoryLayout<rt_msghdr>.size
                if at + MemoryLayout<sockaddr_in>.size <= size {
                    let sin = raw.loadUnaligned(fromByteOffset: at, as: sockaddr_in.self)
                    // Link address follows, 4-byte aligned
                    let next = at + (sin.sin_len > 0 ? (Int(sin.sin_len) + 3) & ~3 : 4)
                    if sin.sin_addr.s_addr == ip.s_addr, next + MemoryLayout<sockaddr_dl>.size <= size {
                        return indexName(UInt32(raw.loadUnaligned(fromByteOffset: next, as: sockaddr_dl.self).sdl_index))
                    }
                }
                offset += length
            }
            return nil
        }
    }

    private static func indexName(_ index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return if_indextoname(index, &name) == nil ? nil : String(cString: name)
    }
}
