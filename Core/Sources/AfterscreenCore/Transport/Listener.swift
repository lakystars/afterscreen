import Darwin
import Foundation

/// 4 MiB buffers, set before connect or listen
/// Accepted sockets inherit them
/// Window scale is fixed at the handshake
/// Resizing after it can leave the peer's FIN undelivered
func sizeBuffers(_ fd: Int32) {
    var buffer: Int32 = 4 << 20
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
}

/// No SIGPIPE, no Nagle
func configure(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Dual-stack TCP listener; accepts on a dedicated thread
public final class Listener {
    public private(set) var port: UInt16 = 0
    public var onAccept: ((Connection) -> Void)?

    private var fd: Int32
    private var thread: Thread?

    public init(port: UInt16 = 0) throws {
        fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.system("socket", errno) }
        var zero: Int32 = 0, one: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        sizeBuffers(fd)
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw TransportError.system("bind/listen", code)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: addr.sin6_port)
    }

    public func start() {
        guard thread == nil else { return }
        let fd = self.fd
        let t = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                configure(client)
                if let self = self, let handler = self.onAccept {
                    handler(Connection(fd: client))
                } else {
                    close(client)
                }
            }
        }
        t.name = "afterscreen.accept"
        thread = t
        t.start()
    }

    public func stop() {
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        fd = -1
    }

    deinit { stop() }
}
