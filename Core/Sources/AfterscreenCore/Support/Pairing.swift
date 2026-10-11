import CryptoKit
import Foundation

/// Pairing on networks; point-to-point cables skip it
/// First time: X25519, then an HMAC binding the shown code
/// Seeing the receiver's screen proves being next to it
/// Afterwards: HMAC proofs with the kept key, both ways
public enum Pairing {
    public typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey

    /// What both sides bind into every MAC
    public struct Transcript: Equatable {
        public var senderID: String
        public var receiverID: String
        public var senderNonce: Data
        public var receiverNonce: Data
        /// Pairing only: both one-time public keys
        public var senderKey = Data()
        public var receiverKey = Data()

        public init(senderID: String, receiverID: String, senderNonce: Data, receiverNonce: Data, senderKey: Data = Data(), receiverKey: Data = Data()) {
            self.senderID = senderID
            self.receiverID = receiverID
            self.senderNonce = senderNonce
            self.receiverNonce = receiverNonce
            self.senderKey = senderKey
            self.receiverKey = receiverKey
        }

        /// Length-prefixed parts: no two transcripts share bytes
        var bytes: Data {
            [Data(senderID.utf8), Data(receiverID.utf8), senderNonce, receiverNonce, senderKey, receiverKey].reduce(into: Data()) { out, part in
                var n = UInt32(part.count).bigEndian
                out.append(Data(bytes: &n, count: 4))
                out.append(part)
            }
        }
    }

    public static func nonce() -> Data {
        Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }

    /// Six digits, uniform
    public static func code() -> String {
        var rng = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &rng))
    }

    public static func newKey() -> PrivateKey { PrivateKey() }

    /// One pairing's key: X25519, then HKDF over the transcript
    public static func sessionKey(_ own: PrivateKey, peer: Data, transcript: Transcript) throws -> SymmetricKey {
        let shared = try own.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript.bytes, sharedInfo: Data("afterscreen pairing".utf8),
                                              outputByteCount: 32)
    }

    /// Sender's proof that its user typed the shown code
    public static func confirm(_ session: SymmetricKey, code: String, transcript: Transcript) -> Data {
        mac(session, "pair-confirm", transcript, extra: Data(code.utf8))
    }

    /// Receiver's proof that it holds the same session key
    public static func pairedProof(_ session: SymmetricKey, transcript: Transcript) -> Data {
        mac(session, "pair-done", transcript)
    }

    /// The key both sides keep
    public static func pairingKey(_ session: SymmetricKey, code: String, transcript: Transcript) -> Data {
        mac(session, "pairing-key", transcript, extra: Data(code.utf8))
    }

    /// Later connections: each side proves the kept key
    public static func proof(key: Data, role: Role, transcript: Transcript) -> Data {
        mac(SymmetricKey(data: key), role.rawValue, transcript)
    }

    public enum Role: String {
        case sender = "auth-sender"
        case receiver = "auth-receiver"
    }

    /// Constant time
    public static func matches(_ mac: Data, _ expected: Data) -> Bool {
        guard mac.count == expected.count else { return false }
        return zip(mac, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func mac(_ key: SymmetricKey, _ label: String, _ transcript: Transcript, extra: Data = Data()) -> Data {
        var h = HMAC<SHA256>(key: key)
        h.update(data: Data(label.utf8))
        h.update(data: transcript.bytes)
        h.update(data: extra)
        return Data(h.finalize())
    }
}
