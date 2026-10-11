import Foundation
import Security

/// Kept pairing keys, one per peer ID
public protocol PairingStoring: AnyObject {
    func key(for peer: String) -> Data?
    /// false when the key could not be kept
    @discardableResult func save(_ key: Data, for peer: String, name: String) -> Bool
    func remove(_ peer: String)
    /// Peers with a key, by name
    var pairs: [(id: String, name: String)] { get }
}

/// Login keychain, generic passwords under one service
/// Account: the peer's ID; label: its name for lists
public final class KeychainPairingStore: PairingStoring {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func key(for peer: String) -> Data? {
        var query = base(peer)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Updates in place: deletes fail on other builds' access lists
    @discardableResult public func save(_ key: Data, for peer: String, name: String) -> Bool {
        let change: [String: Any] = [kSecValueData as String: key, kSecAttrLabel as String: name]
        let updated = SecItemUpdate(base(peer) as CFDictionary, change as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(base(peer).merging(change) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ peer: String) {
        SecItemDelete(base(peer) as CFDictionary)
    }

    public var pairs: [(id: String, name: String)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String else { return nil }
            return (id, item[kSecAttrLabel as String] as? String ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func base(_ peer: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peer]
    }
}

/// In memory, for tests
public final class MemoryPairingStore: PairingStoring {
    private var keys: [String: (key: Data, name: String)] = [:]
    private let lock = NSLock()

    public init() {}

    public func key(for peer: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[peer]?.key
    }

    @discardableResult public func save(_ key: Data, for peer: String, name: String) -> Bool {
        lock.lock()
        keys[peer] = (key, name)
        lock.unlock()
        return true
    }

    public func remove(_ peer: String) {
        lock.lock()
        keys[peer] = nil
        lock.unlock()
    }

    public var pairs: [(id: String, name: String)] {
        lock.lock()
        defer { lock.unlock() }
        return keys.map { ($0.key, $0.value.name) }.sorted { $0.name < $1.name }
    }
}
