import CryptoKit
import XCTest
import AfterscreenCore
@testable import AfterscreenReceiverKit

/// The receiver's side of pairing; the test plays the sender
final class ReceiverPairingTests: XCTestCase {
    private let queue = DispatchQueue(label: "pairing-tests")
    private var listener: Listener!
    private var sessions: [ReceiverSession] = []
    private let display = FakeDisplay()
    private let store = MemoryPairingStore()
    private let limiter = PairingLimiter()
    private var codes: [String?] = []
    private var required = true
    private var proofTimeout: TimeInterval = 10
    private var inbox: [Message] = []
    private var waiter: XCTestExpectation?
    /// Later connections join the first session, as during a session
    private var offerToFirst = false
    private var lastWelcome: Welcome?

    private let welcome = Welcome(protocolVersion: AfterscreenProtocol.version, name: "iMac", modelID: "iMac18,3",
                                  marketingName: "iMac", osVersion: "13.7", gpuNames: [],
                                  panelPixels: PixelSize(width: 5120, height: 2880), panelPoints: PixelSize(width: 2560, height: 1440),
                                  hevcDecode: true, h264Decode: true, bc7: true)
    private let config = StreamConfig(path: .tile, streamPixels: PixelSize(width: 256, height: 128), video: nil, linkKind: .wifi)

    override func setUpWithError() throws {
        listener = try Listener()
        listener.onAccept = { [unowned self] c in
            if offerToFirst, let first = queue.sync(execute: { sessions.first }) { return first.offerChannel(c) }
            var auth = ReceiverAuth(receiverID: "imac", required: required, store: store, limiter: limiter) { [unowned self] code, _ in
                codes.append(code)
            }
            auth.proofTimeout = proofTimeout
            let session = ReceiverSession(connection: c, hardware: welcome, display: display, idleTimeout: 3, auth: auth)
            // Handovers arrive over links that need pairing
            session.admission = { _ in .pairing }
            queue.sync { sessions.append(session) }
            session.start()
        }
        listener.start()
    }

    override func tearDown() {
        listener.stop()
    }

    private func connect() throws -> Connection {
        var client: Connection?
        let connected = expectation(description: "connect")
        Connection.connect(host: "127.0.0.1", port: listener.port, interfaceName: nil, timeout: 2) { client = try? $0.get(); connected.fulfill() }
        wait(for: [connected], timeout: 3)
        let c = try XCTUnwrap(client)
        c.onMessage = { [unowned self] m in
            guard m.type != .stats else { return }
            inbox.append(m)
            waiter?.fulfill()
        }
        c.start(queue: queue)
        return c
    }

    /// Sends, then the next reply other than stats
    private func reply(_ client: Connection, _ message: Message) throws -> Message {
        let e = expectation(description: "reply")
        queue.sync { inbox.removeAll(); waiter = e }
        client.send(message)
        wait(for: [e], timeout: 3)
        return try queue.sync { () -> Message in
            defer { waiter = nil }
            return try XCTUnwrap(inbox.first)
        }
    }

    private func hello(paired: Bool, nonce: Data) throws -> Message {
        try JSONWire.message(.hello, Hello(protocolVersion: AfterscreenProtocol.version, name: "MBP", model: "Mac17,1", osVersion: "27",
                                           senderID: "mac", nonce: nonce, paired: paired))
    }

    private func streams(_ client: Connection) -> Bool {
        display.read { display.begun.removeAll() }
        client.send(try! JSONWire.message(.config, config))
        let deadline = Date().addingTimeInterval(1)
        // The display begins on main: keep its run loop turning
        while Date() < deadline {
            if display.read({ !display.begun.isEmpty }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    /// Hello as an unknown Mac: challenge and shown code
    private func challenge(_ client: Connection) throws -> (nonce: Data, challenge: AuthChallenge, shown: String) {
        let nonce = Pairing.nonce()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: false, nonce: nonce)).payload)
        lastWelcome = w
        let challenge = try XCTUnwrap(w.auth)
        XCTAssertEqual(challenge.mode, .pair)
        XCTAssertEqual(w.receiverID, "imac")
        // The code arrives on main
        let deadline = Date().addingTimeInterval(1)
        while codes.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return (nonce, challenge, try XCTUnwrap(codes.last ?? nil))
    }

    /// The sender's half of a pairing, typing `code`
    private func confirm(_ client: Connection, _ c: (nonce: Data, challenge: AuthChallenge, shown: String), code: String) throws
        -> (reply: Message, key: Data, transcript: Pairing.Transcript, session: SymmetricKey) {
        let own = Pairing.newKey()
        let receiverKey = try XCTUnwrap(c.challenge.publicKey)
        let t = Pairing.Transcript(senderID: "mac", receiverID: "imac", senderNonce: c.nonce, receiverNonce: c.challenge.nonce,
                                   senderKey: own.publicKey.rawRepresentation, receiverKey: receiverKey)
        let session = try Pairing.sessionKey(own, peer: receiverKey, transcript: t)
        let r = try reply(client, try JSONWire.message(.pair, PairConfirm(publicKey: own.publicKey.rawRepresentation,
                                                                          mac: Pairing.confirm(session, code: code, transcript: t))))
        return (r, Pairing.pairingKey(session, code: code, transcript: t), t, session)
    }

    private func pair(_ client: Connection) throws -> (reply: Message, key: Data, transcript: Pairing.Transcript, session: SymmetricKey) {
        let c = try challenge(client)
        return try confirm(client, c, code: c.shown)
    }

    private func wrong(_ shown: String) -> String { shown == "000000" ? "000001" : "000000" }

    func testAnUnknownMacPairsWithTheShownCodeThenStreams() throws {
        let client = try connect()
        XCTAssertFalse(streams(client), "nothing streams before pairing")
        let result = try pair(client)
        XCTAssertEqual(result.reply.type, .paired)
        let proof = try JSONWire.decode(AuthProof.self, from: result.reply.payload)
        XCTAssertTrue(Pairing.matches(proof.mac, Pairing.pairedProof(result.session, transcript: result.transcript)), "the receiver proves the same key")
        XCTAssertEqual(store.key(for: "mac"), result.key)
        XCTAssertEqual(store.pairs.map(\.name), ["MBP"])
        XCTAssertTrue(streams(client))
        XCTAssertNil(codes.last ?? "shown", "the code is hidden once paired")
    }

    /// The usual upgrade: a paired Wi-Fi session onto Ethernet
    func testAPairedSessionHandsOverWithItsKeyOnly() throws {
        let client = try connect()
        let paired = try pair(client)
        XCTAssertTrue(streams(client))
        let token = try XCTUnwrap(lastWelcome?.handoverToken)
        offerToFirst = true
        func attempt(key: Data?) throws -> Message {
            let next = try connect()
            let nonce = Pairing.nonce()
            let challenge = try reply(next, try JSONWire.message(.handover, HandoverNonce(nonce: nonce)))
            XCTAssertEqual(challenge.type, .handoverChallenge)
            let theirs = try JSONWire.decode(HandoverNonce.self, from: challenge.payload).nonce
            let secret = Handover.secret(key: key, token: token)
            let answer = try reply(next, try JSONWire.message(.handoverProof, AuthProof(mac: Handover.proof(secret, role: .sender,
                                                                                                             senderNonce: nonce, receiverNonce: theirs))))
            if answer.type == .handoverOK {
                let proof = try JSONWire.decode(AuthProof.self, from: answer.payload)
                XCTAssertTrue(Pairing.matches(proof.mac, Handover.proof(secret, role: .receiver, senderNonce: nonce, receiverNonce: theirs)))
            }
            next.close(reason: "test end")
            return answer
        }
        XCTAssertEqual(try attempt(key: nil).type, .bye, "the token alone opens nothing on a paired session")
        XCTAssertEqual(try attempt(key: paired.key).type, .handoverOK)
    }

    func testAWrongCodeKeepsTheSameCodeForAnotherTry() throws {
        let client = try connect()
        let c = try challenge(client)
        XCTAssertEqual(try confirm(client, c, code: wrong(c.shown)).reply.type, .pairWrong)
        XCTAssertNil(store.key(for: "mac"))
        XCTAssertEqual(codes.last ?? nil, c.shown, "the code stays up")
        let right = try confirm(client, c, code: c.shown)
        XCTAssertEqual(right.reply.type, .paired)
        XCTAssertEqual(store.key(for: "mac"), right.key)
        XCTAssertTrue(streams(client))
    }

    func testTheFifthWrongCodeLocksPairing() throws {
        let client = try connect()
        let c = try challenge(client)
        for _ in 0..<4 { XCTAssertEqual(try confirm(client, c, code: wrong(c.shown)).reply.type, .pairWrong) }
        XCTAssertEqual(try confirm(client, c, code: wrong(c.shown)).reply.type, .bye, "the fifth ends the session")
        XCTAssertTrue(limiter.locked)
        let next = try connect()
        XCTAssertEqual(try reply(next, try hello(paired: false, nonce: Pairing.nonce())).type, .bye, "locked: no new code shows")
    }

    func testAPairedMacProvesItsKeyAndTheReceiverProvesItBack() throws {
        let key = Pairing.nonce() + Pairing.nonce()
        store.save(key, for: "mac", name: "MBP")
        let client = try connect()
        let nonce = Pairing.nonce()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: true, nonce: nonce)).payload)
        let challenge = try XCTUnwrap(w.auth)
        XCTAssertEqual(challenge.mode, .paired)
        let t = Pairing.Transcript(senderID: "mac", receiverID: "imac", senderNonce: nonce, receiverNonce: challenge.nonce)
        let ok = try reply(client, try JSONWire.message(.auth, AuthProof(mac: Pairing.proof(key: key, role: .sender, transcript: t))))
        XCTAssertEqual(ok.type, .authOK)
        XCTAssertTrue(Pairing.matches(try JSONWire.decode(AuthProof.self, from: ok.payload).mac, Pairing.proof(key: key, role: .receiver, transcript: t)))
        XCTAssertTrue(streams(client))
        XCTAssertTrue(codes.isEmpty, "no code for a paired Mac")
    }

    func testAProofFromAnotherKeyIsRefusedButTheKeyKept() throws {
        let kept = Pairing.nonce() + Pairing.nonce()
        store.save(kept, for: "mac", name: "MBP")
        let client = try connect()
        let nonce = Pairing.nonce()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: true, nonce: nonce)).payload)
        let t = Pairing.Transcript(senderID: "mac", receiverID: "imac", senderNonce: nonce, receiverNonce: try XCTUnwrap(w.auth).nonce)
        let r = try reply(client, try JSONWire.message(.auth, AuthProof(mac: Pairing.proof(key: Pairing.nonce() + Pairing.nonce(), role: .sender, transcript: t))))
        XCTAssertEqual(r.type, .bye)
        XCTAssertEqual(try JSONWire.decode(Bye.self, from: r.payload).repair, true, "the real sender drops its key and pairs afresh")
        XCTAssertEqual(store.key(for: "mac"), kept, "anyone can claim an ID: a bad proof deletes nothing")
        XCTAssertFalse(streams(client))
    }

    func testOnlyTheIssuedChallengeIsAnswered() throws {
        let client = try connect()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: false, nonce: Pairing.nonce())).payload)
        XCTAssertEqual(w.auth?.mode, .pair)
        let e = expectation(description: "no reply")
        e.isInverted = true
        queue.sync { inbox.removeAll(); waiter = e }
        client.send(try JSONWire.message(.auth, AuthProof(mac: Data(count: 32))))
        wait(for: [e], timeout: 0.4)
        XCTAssertFalse(streams(client), "a proof answers no pairing challenge")
    }

    func testAPairedMacProvesItsKeyEvenOverACable() throws {
        required = false
        store.save(Pairing.nonce() + Pairing.nonce(), for: "mac", name: "MBP")
        let client = try connect()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: true, nonce: Pairing.nonce())).payload)
        XCTAssertEqual(w.auth?.mode, .paired, "the sender gets to check this receiver")
    }

    func testAMacWhoseKeyWasRemovedHerePairsAgainOverACable() throws {
        required = false
        let client = try connect()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: true, nonce: Pairing.nonce())).payload)
        XCTAssertEqual(w.auth?.mode, .pair, "it would refuse an unproven receiver; a code settles it")
    }

    func testARepairHelloGetsACodeEvenWithAKeptKey() throws {
        store.save(Pairing.nonce() + Pairing.nonce(), for: "mac", name: "MBP")
        let client = try connect()
        let hello = try JSONWire.message(.hello, Hello(protocolVersion: AfterscreenProtocol.version, name: "MBP", model: "Mac17,1", osVersion: "27",
                                                       senderID: "mac", nonce: Pairing.nonce(), paired: true, repair: true))
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, hello).payload)
        XCTAssertEqual(w.auth?.mode, .pair, "its proof failed before: a code replaces the key")
    }

    func testAnUnansweredChallengeCloses() throws {
        proofTimeout = 0.3
        store.save(Pairing.nonce() + Pairing.nonce(), for: "mac", name: "MBP")
        let client = try connect()
        _ = try reply(client, try hello(paired: true, nonce: Pairing.nonce()))
        let e = expectation(description: "bye")
        queue.sync { inbox.removeAll(); waiter = e }
        wait(for: [e], timeout: 2)
        XCTAssertEqual(queue.sync { inbox.first?.type }, .bye)
    }

    func testEachLockOfTheLimiterLastsUntilAPairingSucceeds() {
        let limiter = PairingLimiter()
        for _ in 0..<4 { limiter.failed() }
        XCTAssertFalse(limiter.locked)
        limiter.failed()
        XCTAssertTrue(limiter.locked)
        limiter.succeeded()
        XCTAssertFalse(limiter.locked)
    }

    func testCablesStreamWithoutPairing() throws {
        required = false
        let client = try connect()
        let w = try JSONWire.decode(Welcome.self, from: try reply(client, try hello(paired: false, nonce: Pairing.nonce())).payload)
        XCTAssertNil(w.auth)
        XCTAssertEqual(w.receiverID, "imac")
        XCTAssertTrue(streams(client))
    }
}
