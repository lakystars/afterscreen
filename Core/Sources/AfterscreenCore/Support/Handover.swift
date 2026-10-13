import CryptoKit
import Foundation

/// A second connection taking over a running session
/// Secret: pairing key with the session token, else the token
/// Both sides prove it over fresh nonces; token stays home
public enum Handover {
    public enum Role: String {
        case sender = "handover-sender"
        case receiver = "handover-receiver"
    }

    /// `key`: the session's pairing key; nil when admitted without one
    public static func secret(key: Data?, token: Data) -> SymmetricKey {
        let label = Data("afterscreen handover".utf8)
        guard let key = key else { return SymmetricKey(data: Data(SHA256.hash(data: label + token))) }
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        h.update(data: label)
        h.update(data: token)
        return SymmetricKey(data: Data(h.finalize()))
    }

    public static func proof(_ secret: SymmetricKey, role: Role, senderNonce: Data, receiverNonce: Data) -> Data {
        var h = HMAC<SHA256>(key: secret)
        h.update(data: Data(role.rawValue.utf8))
        // Fixed-size nonces: no two inputs share bytes
        h.update(data: senderNonce)
        h.update(data: receiverNonce)
        return Data(h.finalize())
    }
}
