import Foundation

public enum MessageType: UInt8, CaseIterable {
    case hello = 0x01
    case welcome = 0x02
    case config = 0x03
    // Pairing on networks; point-to-point cables skip it
    /// Sender's proof of the kept key
    case auth = 0x04
    /// Receiver's proof back
    case authOK = 0x05
    /// Sender's half of a pairing, bound to the shown code
    case pair = 0x06
    /// Receiver kept the pairing; its proof back
    case paired = 0x07
    /// Wrong code; the same code stays up for another try
    case pairWrong = 0x08
    // A second connection taking over the session's link
    /// Sender: first message on the new connection
    case handover = 0x09
    /// Receiver: its nonce for the proof
    case handoverChallenge = 0x0A
    /// Sender's proof of the session secret
    case handoverProof = 0x0B
    /// Receiver's proof back; the switch may start
    case handoverOK = 0x0C
    /// Sender: last message on the old connection
    /// Receiver: echoed on the new one once it reads there
    case switchover = 0x0D
    /// Path and video layer for the new link; picture kept
    case reconfigure = 0x0E
    case tileFrame = 0x10
    case videoParams = 0x11
    case videoFrame = 0x12
    case cursorPos = 0x20
    case cursorImage = 0x21
    /// Sender's panel light; the receiver matches its nits
    case brightness = 0x22
    /// Opens the second connection carrying cursor and sound
    case cursorChannel = 0x23
    case audio = 0x24
    /// Sender's output volume and mute, set on the receiver
    case volume = 0x25
    case deband = 0x26
    /// Sender's disconnect: power-off over the live stream
    /// Receiver says bye once the screen is black
    case powerOff = 0x27
    case probe = 0x30
    case probeResult = 0x31
    case ping = 0x40
    case pong = 0x41
    case stats = 0x50
    /// Sender-side numbers for the receiver's HUD
    case senderStats = 0x51
    case keyRequest = 0x60
    case bye = 0x7F
}

public struct Message {
    public var type: MessageType
    public var flags: UInt8
    public var payload: Data

    public init(type: MessageType, flags: UInt8 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.payload = payload
    }
}

public enum FramingError: Error, Equatable {
    case oversized(Int)
    case unknownType(UInt8)
    case truncated
    case invalid(String)
    case io(Int32)
}

/// Little-endian header:
/// u8 type, u8 flags, u16 reserved, u32 payload length
public enum Framing {
    public static let headerSize = 8
    public static let maxPayload = 64 << 20

    /// Header only, for writers that send the payload separately
    public static func header(type: MessageType, flags: UInt8 = 0, length: Int) -> Data {
        var w = ByteWriter(capacity: headerSize)
        w.u8(type.rawValue)
        w.u8(flags)
        w.u16(0)
        w.u32(UInt32(length))
        return w.data
    }
}

/// Pull parser over a read(2)-like source
/// Headers and small payloads use a 64 KiB read-ahead
/// Larger payloads read straight into pooled buffers
public final class FrameReader {
    /// Like read(2): bytes read, 0 at end, -1 with errno
    public typealias Source = (UnsafeMutableRawPointer, Int) -> Int

    static let aheadSize = 64 << 10
    private let source: Source
    private let pool: BufferPool
    private let ahead = UnsafeMutableRawPointer.allocate(byteCount: aheadSize, alignment: 16)
    private var start = 0
    private var end = 0

    public init(pool: BufferPool = .shared, source: @escaping Source) {
        self.pool = pool
        self.source = source
    }

    deinit { ahead.deallocate() }

    /// nil at end of stream between messages
    public func next() throws -> Message? {
        guard try fill(Framing.headerSize, endOK: true) else { return nil }
        let h = ahead + start
        let rawType = h.load(as: UInt8.self)
        let flags = h.load(fromByteOffset: 1, as: UInt8.self)
        let length = Int(UInt32(littleEndian: h.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
        guard length <= Framing.maxPayload else { throw FramingError.oversized(length) }
        guard let type = MessageType(rawValue: rawType) else { throw FramingError.unknownType(rawType) }
        start += Framing.headerSize

        let payload: Data
        if length <= FrameReader.aheadSize {
            _ = try fill(length, endOK: false)
            payload = Data(bytes: ahead + start, count: length)
            start += length
        } else {
            payload = try pool.data(capacity: length) { dst in
                let have = min(end - start, length)
                dst.copyMemory(from: ahead + start, byteCount: have)
                start += have
                var got = have
                while got < length {
                    let n = try read(dst + got, length - got)
                    guard n > 0 else { throw FramingError.truncated }
                    got += n
                }
                return length
            }
        }
        return Message(type: type, flags: flags, payload: payload)
    }

    /// Buffers at least `count` bytes; false only on clean EOF
    private func fill(_ count: Int, endOK: Bool) throws -> Bool {
        if end - start >= count { return true }
        if start > 0 {
            memmove(ahead, ahead + start, end - start)
            end -= start
            start = 0
        }
        while end < count {
            let n = try read(ahead + end, FrameReader.aheadSize - end)
            if n == 0 {
                if endOK && end == 0 { return false }
                throw FramingError.truncated
            }
            end += n
        }
        return true
    }

    private func read(_ p: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        let n = source(p, count)
        if n < 0 { throw FramingError.io(errno) }
        return n
    }
}

public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
}

public struct ByteReader {
    private let data: Data
    public private(set) var position: Int

    public init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    public var remaining: Int { data.endIndex - position }

    private mutating func take(_ n: Int) throws -> Data.SubSequence {
        guard n >= 0, remaining >= n else { throw FramingError.truncated }
        defer { position += n }
        return data[position..<(position + n)]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }

    public mutating func u16() throws -> UInt16 {
        let s = try take(2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        let s = try take(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(s[s.startIndex + i]) << (8 * UInt32(i)) }
        return v
    }

    public mutating func u64() throws -> UInt64 {
        let s = try take(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(s[s.startIndex + i]) << (8 * UInt64(i)) }
        return v
    }

    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    /// Slice of the source; shares its storage
    public mutating func bytes(_ n: Int) throws -> Data { try take(n) }

    /// Slice of the source; shares its storage
    public mutating func rest() -> Data {
        defer { position = data.endIndex }
        return data[position..<data.endIndex]
    }
}
