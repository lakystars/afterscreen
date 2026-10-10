import XCTest
@testable import AfterscreenCore

extension Framing {
    /// Header and payload in one buffer
    static func encode(_ m: Message) -> Data {
        header(type: m.type, flags: m.flags, length: m.payload.count) + m.payload
    }
}

final class FramingTests: XCTestCase {
    /// Reader over `data`, delivering at most `piece` bytes per read like a socket
    private func reader(_ data: Data, piece: Int = .max) -> FrameReader {
        var offset = 0
        return FrameReader { dst, count in
            let n = min(count, piece, data.count - offset)
            data.withUnsafeBytes { src in dst.copyMemory(from: src.baseAddress! + offset, byteCount: n) }
            offset += n
            return n
        }
    }

    func testRoundTripEveryType() throws {
        var stream = Data()
        for (i, type) in MessageType.allCases.enumerated() {
            stream += Framing.encode(Message(type: type, flags: UInt8(i), payload: Data((0..<i).map { UInt8($0) })))
        }
        let r = reader(stream)
        for (i, type) in MessageType.allCases.enumerated() {
            let m = try XCTUnwrap(r.next())
            XCTAssertEqual(m.type, type)
            XCTAssertEqual(m.flags, UInt8(i))
            XCTAssertEqual(m.payload, Data((0..<i).map { UInt8($0) }))
        }
        XCTAssertNil(try r.next())
    }

    func testByteAtATimeDelivery() throws {
        let r = reader(Framing.encode(Message(type: .stats, payload: Data("hello".utf8))), piece: 1)
        XCTAssertEqual(try r.next()?.payload, Data("hello".utf8))
        XCTAssertNil(try r.next())
    }

    func testLargePayloadSpanningReadsArrivesIntact() throws {
        let big = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var stream = Framing.encode(Message(type: .ping, payload: Data([1])))
        stream += Framing.encode(Message(type: .tileFrame, payload: big))
        stream += Framing.encode(Message(type: .pong, payload: Data([2])))
        let r = reader(stream, piece: 300_001)
        XCTAssertEqual(try r.next()?.type, .ping)
        XCTAssertEqual(try r.next()?.payload, big)
        XCTAssertEqual(try r.next()?.payload, Data([2]))
        XCTAssertNil(try r.next())
    }

    func testEndOfStreamInsideAMessageIsTruncated() {
        let r = reader(Framing.encode(Message(type: .stats, payload: Data(count: 100))).prefix(50))
        XCTAssertThrowsError(try r.next()) { XCTAssertEqual($0 as? FramingError, .truncated) }
    }

    func testOversizedLengthThrows() {
        var w = ByteWriter()
        w.u8(MessageType.tileFrame.rawValue); w.u8(0); w.u16(0); w.u32(UInt32(Framing.maxPayload + 1))
        XCTAssertThrowsError(try reader(w.data).next()) { error in
            XCTAssertEqual(error as? FramingError, .oversized(Framing.maxPayload + 1))
        }
    }

    func testUnknownTypeThrows() {
        var w = ByteWriter()
        w.u8(0x99); w.u8(0); w.u16(0); w.u32(0)
        XCTAssertThrowsError(try reader(w.data).next()) { error in
            XCTAssertEqual(error as? FramingError, .unknownType(0x99))
        }
    }

    func testReadErrorIsReported() {
        let r = FrameReader { _, _ in
            errno = ECONNRESET
            return -1
        }
        XCTAssertThrowsError(try r.next()) { XCTAssertEqual($0 as? FramingError, .io(ECONNRESET)) }
    }

    func testPooledBufferIsReusedAfterRelease() {
        let pool = BufferPool(keep: 2)
        var first: UnsafeRawPointer?
        do {
            let d = pool.data(capacity: 3 << 20) { _ in 3 << 20 }
            first = d.withUnsafeBytes { $0.baseAddress }
        }
        let again = pool.data(capacity: (3 << 20) - 100) { _ in (3 << 20) - 100 }
        XCTAssertEqual(again.withUnsafeBytes { $0.baseAddress }, first)
        XCTAssertEqual(again.count, (3 << 20) - 100)
    }

    func testPoolKeepsAtMostItsLimit() {
        let pool = BufferPool(keep: 2)
        do { _ = (0..<5).map { _ in pool.data(capacity: 1 << 20) { _ in 1 << 20 } } }
        XCTAssertEqual(pool.freeCount, 2)
    }

    func testSenderStatsMessageIsProtocolVersionTen() {
        XCTAssertEqual(AfterscreenProtocol.version, 10)
        XCTAssertEqual(MessageType.powerOff.rawValue, 0x27)
        XCTAssertEqual(MessageType.senderStats.rawValue, 0x51)
        XCTAssertEqual(MessageType.deband.rawValue, 0x26)
    }

    func testDebandWireCarriesOneLevelByte() throws {
        for level in Deband.allCases { XCTAssertEqual(try DebandWire.decode(DebandWire.encode(level)), level) }
        XCTAssertEqual(DebandWire.encode(.strong), Data([3]))
        XCTAssertThrowsError(try DebandWire.decode(Data([9])))
        XCTAssertThrowsError(try DebandWire.decode(Data()))
        XCTAssertEqual(Deband.allCases.map(\.rangePixels), [0, 16, 32, 64])
    }

    func testPoolKnowsItsOwnBuffers() {
        let pool = BufferPool(keep: 2)
        let pooled = pool.data(capacity: 2 << 20) { _ in 2 << 20 }
        let other = Data(count: 2 << 20)
        XCTAssertNotNil(pooled.withUnsafeBytes { pool.capacity(of: $0.baseAddress!) })
        XCTAssertNil(other.withUnsafeBytes { pool.capacity(of: $0.baseAddress!) })
    }

    func testIdleBuffersAreReleasedWithoutACaller() {
        let pool = BufferPool(keep: 4, idleSeconds: 0.1)
        do { _ = pool.data(capacity: 1 << 20) { _ in 1 } }
        XCTAssertEqual(pool.freeCount, 1)
        let gone = expectation(description: "trimmed")
        func check() {
            if pool.freeCount == 0 { gone.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check) }
        }
        check()
        wait(for: [gone], timeout: 2)
    }

    func testUnmapObserversRunBeforeABufferIsReleased() {
        let pool = BufferPool(keep: 4, idleSeconds: 0.05)
        var base: UnsafeRawPointer?
        do {
            // Large enough that Data keeps the buffer instead of copying inline
            let d = pool.data(capacity: 1 << 20) { _ in 4096 }
            base = d.withUnsafeBytes { $0.baseAddress }
            XCTAssertEqual(pool.capacity(of: base!), 1 << 20)
        }
        let seen = expectation(description: "unmapped")
        pool.addUnmapObserver { p in
            if UnsafeRawPointer(p) == base { seen.fulfill() }
        }
        wait(for: [seen], timeout: 2)
        XCTAssertNil(pool.capacity(of: base!))
    }

    func testHardwareModelIsKnown() {
        XCTAssertFalse(HardwareModel.identifier.isEmpty)
    }

    func testByteReaderSlicesShareStorage() throws {
        var w = ByteWriter()
        w.u8(1); w.bytes(Data([9, 8, 7]))
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.u8(), 1)
        XCTAssertEqual(r.rest(), Data([9, 8, 7]))
    }

    func testReaderPastEndThrows() throws {
        var w = ByteWriter()
        w.u16(0xBEEF)
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.u16(), 0xBEEF)
        XCTAssertThrowsError(try r.u8()) { error in
            XCTAssertEqual(error as? FramingError, .truncated)
        }
    }

    func testLittleEndianLayout() {
        var w = ByteWriter()
        w.u32(0x0403_0201); w.u64(0x0807_0605_0403_0201); w.f32(1.0)
        XCTAssertEqual(Array(w.data.prefix(12)), [1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(Array(w.data.suffix(4)), [0x00, 0x00, 0x80, 0x3F])
    }
}
