import Foundation

public extension UserDefaults {
    /// Stored raw value as `T`; `fallback` when unset or unknown
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}
