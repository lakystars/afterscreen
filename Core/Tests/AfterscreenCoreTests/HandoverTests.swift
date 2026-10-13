import XCTest
@testable import AfterscreenCore

final class HandoverTests: XCTestCase {
    private let token = Pairing.nonce(), key = Pairing.nonce()
    private let sender = Pairing.nonce(), receiver = Pairing.nonce()

    func testBothSidesDeriveTheSameProofs() {
        let a = Handover.secret(key: key, token: token), b = Handover.secret(key: key, token: token)
        XCTAssertEqual(Handover.proof(a, role: .sender, senderNonce: sender, receiverNonce: receiver),
                       Handover.proof(b, role: .sender, senderNonce: sender, receiverNonce: receiver))
    }

    func testProofsBindRoleNoncesKeyAndToken() {
        let secret = Handover.secret(key: key, token: token)
        let proof = Handover.proof(secret, role: .sender, senderNonce: sender, receiverNonce: receiver)
        XCTAssertNotEqual(proof, Handover.proof(secret, role: .receiver, senderNonce: sender, receiverNonce: receiver), "no reflection")
        XCTAssertNotEqual(proof, Handover.proof(secret, role: .sender, senderNonce: sender, receiverNonce: Pairing.nonce()), "fresh challenge")
        XCTAssertNotEqual(proof, Handover.proof(Handover.secret(key: Pairing.nonce(), token: token), role: .sender,
                                                senderNonce: sender, receiverNonce: receiver), "another pairing")
        XCTAssertNotEqual(proof, Handover.proof(Handover.secret(key: key, token: Pairing.nonce()), role: .sender,
                                                senderNonce: sender, receiverNonce: receiver), "another session")
        XCTAssertNotEqual(proof, Handover.proof(Handover.secret(key: nil, token: token), role: .sender,
                                                senderNonce: sender, receiverNonce: receiver), "the key matters when there is one")
    }

    func testWelcomeCarriesTheTokenOnlyWhenSet() throws {
        var welcome = Welcome(protocolVersion: 1, name: "iMac", modelID: "iMac18,3", marketingName: "iMac", osVersion: "13.7",
                              gpuNames: [], panelPixels: PixelSize(width: 5120, height: 2880), panelPoints: PixelSize(width: 2560, height: 1440),
                              hevcDecode: true, h264Decode: true, bc7: true)
        XCTAssertFalse(String(decoding: try JSONWire.encode(welcome), as: UTF8.self).contains("handoverToken"), "older senders see nothing new")
        welcome.handoverToken = token
        XCTAssertEqual(try JSONWire.decode(Welcome.self, from: try JSONWire.encode(welcome)).handoverToken, token)
    }
}
