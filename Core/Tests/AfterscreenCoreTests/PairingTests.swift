import XCTest
@testable import AfterscreenCore

final class PairingTests: XCTestCase {
    private func transcript(_ s: Pairing.PrivateKey, _ r: Pairing.PrivateKey, sn: Data, rn: Data) -> Pairing.Transcript {
        Pairing.Transcript(senderID: "mac", receiverID: "imac", senderNonce: sn, receiverNonce: rn,
                           senderKey: s.publicKey.rawRepresentation, receiverKey: r.publicKey.rawRepresentation)
    }

    func testTheShownCodePairsBothSidesOnOneKey() throws {
        let s = Pairing.newKey(), r = Pairing.newKey(), sn = Pairing.nonce(), rn = Pairing.nonce()
        let t = transcript(s, r, sn: sn, rn: rn)
        let senderSession = try Pairing.sessionKey(s, peer: r.publicKey.rawRepresentation, transcript: t)
        let receiverSession = try Pairing.sessionKey(r, peer: s.publicKey.rawRepresentation, transcript: t)
        let code = Pairing.code()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(Pairing.matches(Pairing.confirm(senderSession, code: code, transcript: t),
                                      Pairing.confirm(receiverSession, code: code, transcript: t)))
        XCTAssertFalse(Pairing.matches(Pairing.confirm(senderSession, code: "000000", transcript: t),
                                       Pairing.confirm(receiverSession, code: code == "000000" ? "000001" : code, transcript: t)), "wrong code")
        XCTAssertEqual(Pairing.pairingKey(senderSession, code: code, transcript: t), Pairing.pairingKey(receiverSession, code: code, transcript: t))
        XCTAssertEqual(Pairing.pairedProof(senderSession, transcript: t), Pairing.pairedProof(receiverSession, transcript: t))
    }

    func testProofsAreBoundToRoleAndNonces() {
        let key = Pairing.nonce() + Pairing.nonce()
        let t = Pairing.Transcript(senderID: "mac", receiverID: "imac", senderNonce: Pairing.nonce(), receiverNonce: Pairing.nonce())
        let sender = Pairing.proof(key: key, role: .sender, transcript: t)
        XCTAssertTrue(Pairing.matches(sender, Pairing.proof(key: key, role: .sender, transcript: t)))
        XCTAssertFalse(Pairing.matches(sender, Pairing.proof(key: key, role: .receiver, transcript: t)), "a proof cannot be echoed back")
        var replay = t
        replay.receiverNonce = Pairing.nonce()
        XCTAssertFalse(Pairing.matches(sender, Pairing.proof(key: key, role: .sender, transcript: replay)), "fresh nonce: no replay")
        XCTAssertFalse(Pairing.matches(sender, Pairing.proof(key: Pairing.nonce() + Pairing.nonce(), role: .sender, transcript: t)))
    }

    func testTranscriptPartsCannotShiftIntoEachOther() {
        let a = Pairing.Transcript(senderID: "ab", receiverID: "c", senderNonce: Data(), receiverNonce: Data())
        let b = Pairing.Transcript(senderID: "a", receiverID: "bc", senderNonce: Data(), receiverNonce: Data())
        XCTAssertNotEqual(a.bytes, b.bytes)
    }

    func testMemoryStoreKeepsKeysByPeer() {
        let store = MemoryPairingStore()
        store.save(Data([1]), for: "x", name: "iMac")
        XCTAssertEqual(store.key(for: "x"), Data([1]))
        XCTAssertEqual(store.pairs.map(\.name), ["iMac"])
        store.remove("x")
        XCTAssertNil(store.key(for: "x"))
    }
}
