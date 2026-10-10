import XCTest
@testable import AfterscreenCore

final class TransportTests: XCTestCase {
    private let queue = DispatchQueue(label: "transport-tests")
    private var listener: Listener!

    override func setUpWithError() throws {
        listener = try Listener(port: 0)
    }

    override func tearDown() {
        listener.stop()
    }

    /// Returns (client, server) once both sides exist
    private func pair() throws -> (Connection, Connection) {
        var server: Connection?
        let accepted = expectation(description: "accept")
        listener.onAccept = { c in server = c; accepted.fulfill() }
        listener.start()
        var client: Connection?
        let connected = expectation(description: "connect")
        Connection.connect(host: "127.0.0.1", port: listener.port, interfaceName: nil, timeout: 2) { result in
            client = try? result.get()
            connected.fulfill()
        }
        wait(for: [accepted, connected], timeout: 3)
        return (try XCTUnwrap(client), try XCTUnwrap(server))
    }

    func testMessagesBothWays() throws {
        let (client, server) = try pair()
        var atServer: [Message] = [], atClient: [Message] = []
        let serverGot = expectation(description: "server"), clientGot = expectation(description: "client")
        serverGot.expectedFulfillmentCount = 3
        clientGot.expectedFulfillmentCount = 3
        server.onMessage = { atServer.append($0); serverGot.fulfill() }
        client.onMessage = { atClient.append($0); clientGot.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        for i in 0..<3 {
            client.send(Message(type: .ping, payload: Data([UInt8(i)])))
            server.send(Message(type: .pong, payload: Data([UInt8(10 + i)])))
        }
        wait(for: [serverGot, clientGot], timeout: 3)
        XCTAssertEqual(atServer.map(\.payload), [Data([0]), Data([1]), Data([2])])
        XCTAssertEqual(atClient.map(\.payload), [Data([10]), Data([11]), Data([12])])
        client.close(reason: "done")
    }

    func testLargePayloadArrivesIntact() throws {
        let (client, server) = try pair()
        let big = Data((0..<(32 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let got = expectation(description: "big")
        var received: Data?
        server.onMessage = { received = $0.payload; got.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        client.send(Message(type: .tileFrame, payload: big))
        wait(for: [got], timeout: 10)
        XCTAssertEqual(received, big)
        client.close(reason: "done")
    }

    func testPacedWritesHoldTheConfiguredRate() throws {
        let (client, server) = try pair()
        client.paceBitsPerSecond = 80e6
        let got = expectation(description: "paced")
        got.expectedFulfillmentCount = 4
        server.onMessage = { _ in got.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        let start = Date()
        for _ in 0..<4 { client.send(Message(type: .tileFrame, payload: Data(count: 500_000))) }
        wait(for: [got], timeout: 5)
        // 500 KB at 80 Mbps holds the writer 0.05 s, so the fourth write starts after 0.15 s
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.14)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        client.close(reason: "done")
    }

    func testPeerCloseFiresOnceWithReason() throws {
        let (client, server) = try pair()
        let closed = expectation(description: "closed")
        closed.assertForOverFulfill = true
        var reason: String?
        server.onClose = { reason = $0; closed.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        client.close(reason: "bye")
        wait(for: [closed], timeout: 3)
        XCTAssertNotNil(reason)
        server.close(reason: "again")
        let settle = expectation(description: "settle")
        queue.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
    }

    func testMessagesWrittenBeforeCloseAreDelivered() throws {
        let (client, server) = try pair()
        var got: [MessageType] = []
        let closed = expectation(description: "closed")
        client.onMessage = { got.append($0.type) }
        client.onClose = { _ in closed.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        server.send(Message(type: .welcome))
        server.send(Message(type: .bye))
        server.closeAfterFlush(reason: "done")
        wait(for: [closed], timeout: 3)
        XCTAssertEqual(got, [.welcome, .bye])
    }

    func testOversizedHeaderClosesSession() throws {
        let (client, server) = try pair()
        let closed = expectation(description: "closed")
        var reason = ""
        server.onClose = { reason = $0; closed.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        var w = ByteWriter()
        w.u8(MessageType.tileFrame.rawValue); w.u8(0); w.u16(0); w.u32(100 << 20)
        client.sendRaw(w.data)
        wait(for: [closed], timeout: 3)
        XCTAssertTrue(reason.contains("oversized"), reason)
    }

    func testTCPInfoAndInterface() throws {
        let (client, _) = try pair()
        client.start(queue: queue)
        let info = try XCTUnwrap(client.tcpInfo())
        XCTAssertGreaterThanOrEqual(info.retransmittedPackets, 0)
        XCTAssertGreaterThanOrEqual(info.rttVarMs, 0)
        XCTAssertEqual(client.localInterfaceName, "lo0")
        client.close(reason: "done")
    }

    func testInterfaceMTU() {
        XCTAssertEqual(Interfaces.mtu("lo0"), 16384)
        XCTAssertNil(Interfaces.mtu("nope0"))
    }

    func testConnectFailureReportsError() {
        listener.stop()
        let done = expectation(description: "fail")
        Connection.connect(host: "127.0.0.1", port: 1, interfaceName: nil, timeout: 1) { result in
            if case .failure = result { done.fulfill() }
        }
        wait(for: [done], timeout: 3)
    }

    func testPartsArriveAsOnePayload() throws {
        let (client, server) = try pair()
        let got = expectation(description: "payload")
        var payload = Data()
        server.onMessage = { payload = $0.payload; got.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        client.send(.tileFrame, parts: [Data([1, 2, 3]), big, Data(), Data([9])])
        wait(for: [got], timeout: 5)
        XCTAssertEqual(payload, Data([1, 2, 3]) + big + Data([9]))
        client.close(reason: "done")
    }

    func testFrameWrittenFiresForPictureMessagesOnly() throws {
        let (client, server) = try pair()
        var written = 0
        let done = expectation(description: "written")
        client.onFrameWritten = { written += 1; done.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue)
        client.send(Message(type: .cursorPos, payload: Data(count: 9)))
        client.send(.tileFrame, parts: [Data(count: 1000)])
        wait(for: [done], timeout: 3)
        XCTAssertEqual(written, 1)
        client.close(reason: "done")
    }

    // MARK: - Liveness and flow control

    func testSilentPeerTimesOut() throws {
        let (client, server) = try pair()
        let closed = expectation(description: "closed")
        var reason = ""
        client.onClose = { reason = $0; closed.fulfill() }
        server.start(queue: queue)
        client.start(queue: queue, idleTimeout: 0.5)
        wait(for: [closed], timeout: 3)
        XCTAssertTrue(reason.contains("no data"), reason)
        server.close(reason: "done")
    }

    func testCloseAfterFlushGivesUpWhenPeerStopsReading() throws {
        let (client, server) = try pair()
        let closed = expectation(description: "closed")
        var reason = ""
        client.onClose = { reason = $0; closed.fulfill() }
        client.start(queue: queue)
        client.send(Message(type: .tileFrame, payload: Data(count: 48 << 20)))
        client.closeAfterFlush(reason: "stopped", grace: 0.3)
        wait(for: [closed], timeout: 3)
        XCTAssertEqual(reason, "stopped")
        server.close(reason: "done")
    }

    func testUnstartedConnectionClosesSocketOnRelease() throws {
        var (client, server): (Connection?, Connection) = try pair()
        let closed = expectation(description: "closed")
        server.onClose = { _ in closed.fulfill() }
        server.start(queue: queue)
        XCTAssertNotNil(client)
        client = nil
        wait(for: [closed], timeout: 3)
    }

    func testQueuedFramesCountsOnlyPictureMessages() throws {
        let (client, server) = try pair()
        client.start(queue: queue)
        client.send(Message(type: .tileFrame, payload: Data(count: 48 << 20)))
        for _ in 0..<10 { client.send(Message(type: .cursorPos, payload: Data(count: 9))) }
        // A video frame always precedes the tile frame that presents it
        client.send(Message(type: .videoFrame, payload: Data(count: 9)))
        XCTAssertEqual(client.queuedFrames, 1)
        XCTAssertEqual(client.queuedMessages, 12)
        client.close(reason: "done")
        server.close(reason: "done")
    }

    func testReadGateHoldsDeliveryOnReaderThread() throws {
        let (client, server) = try pair()
        let gate = DispatchSemaphore(value: 0)
        var delivered = 0
        let first = expectation(description: "first")
        let all = expectation(description: "all")
        server.readGate = { m in if m.payload.first == 1 { gate.wait() } }
        server.onMessage = { _ in
            delivered += 1
            if delivered == 1 { first.fulfill() }
            if delivered == 3 { all.fulfill() }
        }
        server.start(queue: queue)
        client.start(queue: queue)
        for i in 0..<3 { client.send(Message(type: .tileFrame, payload: Data([UInt8(i)]))) }
        wait(for: [first], timeout: 3)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(queue.sync { delivered }, 1)
        gate.signal()
        wait(for: [all], timeout: 3)
        client.close(reason: "done")
    }
}
