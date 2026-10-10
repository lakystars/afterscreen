import Darwin
import Foundation

public struct TCPInfo: Equatable {
    public var sentPackets: UInt64
    public var retransmittedPackets: UInt64
    public var rttMs: Double
    /// Kernel RTT variance; transport jitter without app-level queueing
    public var rttVarMs: Double

    public init(sentPackets: UInt64, retransmittedPackets: UInt64, rttMs: Double, rttVarMs: Double) {
        self.sentPackets = sentPackets
        self.retransmittedPackets = retransmittedPackets
        self.rttMs = rttMs
        self.rttVarMs = rttVarMs
    }

    public var retransmitPercent: Double {
        sentPackets > 0 ? Double(retransmittedPackets) / Double(sentPackets) * 100 : 0
    }
}

public enum TransportError: Error, CustomStringConvertible {
    case system(String, Int32)
    case resolve(String)
    case timeout

    public var description: String {
        switch self {
        case let .system(call, code): return "\(call): \(String(cString: strerror(code)))"
        case let .resolve(host): return "cannot resolve \(host)"
        case .timeout: return "connection timed out"
        }
    }
}

/// Framed message connection over a blocking TCP socket
/// Reads on a dedicated thread, writes on a serial queue
/// Callbacks run on the `start` queue
public final class Connection {
    public var onMessage: ((Message) -> Void)?
    /// Called once
    public var onClose: ((String) -> Void)?
    /// Runs on the reader thread before each delivery
    /// Blocking it stops reading (TCP backpressure)
    /// Set before `start`
    public var readGate: ((Message) -> Void)?
    /// Writer queue: a tile frame has been written
    public var onFrameWritten: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return frameWritten }
        set { lock.lock(); frameWritten = newValue; lock.unlock() }
    }
    private var frameWritten: (() -> Void)?
    /// Caps the write rate; simulates a slower link on loopback
    public var paceBitsPerSecond: Double? {
        get { lock.lock(); defer { lock.unlock() }; return pace }
        set { lock.lock(); pace = newValue; lock.unlock() }
    }
    private var pace: Double?
    /// Writer queue only: when the paced link is free again
    private var paceClock = 0.0

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var queuedPictures = 0
    private var started = false
    private var lastRead = ProcessInfo.processInfo.systemUptime
    private var gated = false
    private var watchdog: DispatchSourceTimer?
    private var delegateQueue: DispatchQueue?
    private let writer = DispatchQueue(label: "afterscreen.write")
    private var readerFinished = false
    private var writerReleased = false
    /// Touched only on the delegate queue
    private var closeNotified = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// An unstarted connection owns its fd outright
    deinit {
        if !started && !closed { Darwin.close(fd) }
    }

    /// Messages handed to `send` that are not yet written
    public var queuedMessages: Int {
        lock.lock(); defer { lock.unlock() }
        return queued
    }

    /// Tile and probe messages not yet written
    public var queuedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedPictures
    }

    /// Tile frames stand for whole frames
    /// Hybrid path: every video frame precedes a tile frame
    private static func isPicture(_ type: MessageType) -> Bool {
        type == .tileFrame || type == .probe
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    public static func connect(host: String, port: UInt16, interfaceName: String?, timeout: TimeInterval,
                               completion: @escaping (Result<Connection, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Result { try connectBlocking(host: host, port: port, interfaceName: interfaceName, timeout: timeout) })
        }
    }

    private static func connectBlocking(host: String, port: UInt16, interfaceName: String?, timeout: TimeInterval) throws -> Connection {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw TransportError.resolve(host)
        }
        defer { freeaddrinfo(list) }
        var lastError: Error = TransportError.resolve(host)
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { lastError = TransportError.system("socket", errno); continue }
            sizeBuffers(fd)
            if let name = interfaceName {
                var index = UInt32(if_nametoindex(name))
                if ai.pointee.ai_family == AF_INET6 {
                    setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                } else {
                    setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                }
            }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var result = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if result != 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Int32(timeout * 1000))
                if ready == 1 {
                    var soError: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                    result = soError == 0 ? 0 : -1
                    if soError != 0 { lastError = TransportError.system("connect", soError) }
                } else {
                    lastError = TransportError.timeout
                    result = -1
                }
            } else if result != 0 {
                lastError = TransportError.system("connect", errno)
            }
            if result == 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                configure(fd)
                return Connection(fd: fd)
            }
            Darwin.close(fd)
        }
        throw lastError
    }

    /// `idleTimeout`: close when no bytes arrive for that long
    public func start(queue: DispatchQueue, idleTimeout: TimeInterval? = nil) {
        lock.lock()
        delegateQueue = queue
        started = true
        lastRead = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if let timeout = idleTimeout { startWatchdog(timeout: timeout, queue: queue) }
        let t = Thread { [self] in readLoop() }
        t.name = "afterscreen.read"
        t.start()
    }

    private func startWatchdog(timeout: TimeInterval, queue: DispatchQueue) {
        let period = min(0.5, timeout / 2)
        let timer = DispatchSource.repeating(on: queue, every: period, after: period) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let idle = self.gated ? 0 : ProcessInfo.processInfo.systemUptime - self.lastRead
            self.lock.unlock()
            if idle > timeout { self.close(reason: String(format: "no data from peer for %.0f s", idle)) }
        }
        lock.lock()
        watchdog = timer
        let isClosed = closed
        lock.unlock()
        // A close before this point found no watchdog to cancel
        if isClosed { timer.cancel() }
    }

    private func markRead(gated: Bool) {
        lock.lock()
        self.gated = gated
        lastRead = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func readLoop() {
        let reader = FrameReader { [fd] p, count in
            while true {
                // Payload reads fill 1 MiB per call
                // Each slice feeds the idle watchdog
                let large = count > FrameReader.aheadSize
                let n = recv(fd, p, large ? min(count, 1 << 20) : count, large ? MSG_WAITALL : 0)
                if n < 0 && errno == EINTR { continue }
                if n > 0 { self.markRead(gated: false) }
                return n
            }
        }
        var reason = "connection closed by peer"
        let gate = readGate
        do {
            while let m = try reader.next() {
                if let gate = gate {
                    markRead(gated: true)
                    gate(m)
                    markRead(gated: false)
                }
                deliver(m)
            }
        } catch let error as FramingError {
            switch error {
            case let .oversized(n): reason = "protocol error: oversized message (\(n) bytes)"
            case let .unknownType(t): reason = "protocol error: unknown message type \(t)"
            case let .io(code): reason = "read: \(String(cString: strerror(code)))"
            case .truncated: break
            case .invalid: reason = "protocol error: \(error)"
            }
        } catch {
            reason = "protocol error: \(error)"
        }
        close(reason: reason)
        lock.lock()
        readerFinished = true
        let release = writerReleased
        lock.unlock()
        if release { Darwin.close(fd) }
    }

    /// Messages read before EOF precede onClose on delegate queue
    private func deliver(_ m: Message) {
        lock.lock()
        let queue = delegateQueue
        lock.unlock()
        queue?.async { [weak self] in
            guard let self = self, !self.closeNotified else { return }
            self.onMessage?(m)
        }
    }

    public func send(_ m: Message) {
        enqueue([Framing.header(type: m.type, flags: m.flags, length: m.payload.count), m.payload], picture: Connection.isPicture(m.type))
    }

    /// Payload is `parts` back to back, written without copying
    public func send(_ type: MessageType, flags: UInt8 = 0, parts: [Data]) {
        let length = parts.reduce(0) { $0 + $1.count }
        enqueue([Framing.header(type: type, flags: flags, length: length)] + parts, picture: Connection.isPicture(type))
    }

    /// Control message with a JSON payload
    public func send<T: Encodable>(_ type: MessageType, json value: T) {
        guard let m = try? JSONWire.message(type, value) else { return }
        send(m)
    }

    /// Writes bytes as-is; used by tests to inject malformed frames
    public func sendRaw(_ parts: Data...) {
        enqueue(parts, picture: false)
    }

    private func enqueue(_ parts: [Data], picture: Bool) {
        lock.lock()
        if closed { lock.unlock(); return }
        queued += 1
        if picture { queuedPictures += 1 }
        lock.unlock()
        writer.async { [self] in
            var vecs: [iovec] = []
            vecs.reserveCapacity(parts.count)
            let ok = Connection.withIovecs(parts[...], &vecs) { writeAll(&$0) }
            lock.lock()
            queued -= 1
            if picture { queuedPictures -= 1 }
            let written = picture ? frameWritten : nil
            lock.unlock()
            if !ok { close(reason: "write: \(String(cString: strerror(errno)))") }
            written?()
        }
    }

    /// Calls `body` with one iovec per non-empty part
    /// Pointers valid only inside `body`
    private static func withIovecs(_ parts: ArraySlice<Data>, _ vecs: inout [iovec], _ body: (inout [iovec]) -> Bool) -> Bool {
        guard let first = parts.first else { return body(&vecs) }
        return first.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                vecs.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: raw.count))
            }
            return withIovecs(parts.dropFirst(), &vecs, body)
        }
    }

    /// One writev per message; partial writes advance through the vector
    private func writeAll(_ vecs: inout [iovec]) -> Bool {
        var i = 0
        while i < vecs.count {
            if isClosed { return false }
            let n = vecs.withUnsafeBufferPointer { writev(fd, $0.baseAddress! + i, Int32(min(vecs.count - i, Int(IOV_MAX)))) }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            throttle(bytes: n)
            var left = n
            while left > 0, i < vecs.count {
                if left >= vecs[i].iov_len {
                    left -= vecs[i].iov_len
                    i += 1
                } else {
                    vecs[i].iov_base += left
                    vecs[i].iov_len -= left
                    left = 0
                }
            }
        }
        return true
    }

    private func throttle(bytes: Int) {
        guard let rate = paceBitsPerSecond, rate > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        paceClock = max(paceClock, now) + Double(bytes) * 8 / rate
        if paceClock > now { usleep(UInt32(min(1, paceClock - now) * 1e6)) }
    }

    /// Closes once messages queued so far are written
    /// Forced close after `grace` seconds
    public func closeAfterFlush(reason: String, grace: TimeInterval = 1) {
        writer.async { [self] in close(reason: reason) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in self?.close(reason: reason) }
    }

    public func close(reason: String) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let queue = delegateQueue
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        timer?.cancel()
        shutdown(fd, SHUT_RDWR)
        // fd released after reader exit and pending writes
        writer.async { [self] in
            lock.lock()
            writerReleased = true
            let release = readerFinished || delegateQueue == nil
            lock.unlock()
            if release { Darwin.close(fd) }
        }
        let notify = { [weak self] in
            guard let self = self else { return }
            self.closeNotified = true
            let handler = self.onClose
            self.onClose = nil
            handler?(reason)
        }
        if let queue = queue { queue.async(execute: notify) } else { notify() }
    }

    public func tcpInfo() -> TCPInfo? {
        guard !isClosed else { return nil }
        var info = tcp_connection_info()
        var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
        guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0 else { return nil }
        return TCPInfo(sentPackets: info.tcpi_txpackets, retransmittedPackets: info.tcpi_txretransmitpackets,
                       rttMs: Double(info.tcpi_srtt), rttVarMs: Double(info.tcpi_rttvar))
    }

    /// Interface that carries this connection (from the local address)
    public var localInterfaceName: String? {
        address(getsockname).flatMap(Interfaces.name(forLocalAddress:))
    }

    /// Remote IP literal
    public var peerAddress: String? {
        address(getpeername).flatMap(Interfaces.string)
    }

    /// `getsockname` or `getpeername` of the socket
    private func address(_ query: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { query(fd, $0, &len) }
        }
        return ok == 0 ? storage : nil
    }
}
