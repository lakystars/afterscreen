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
}
