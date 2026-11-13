import Foundation

/// This app's version, and release tag order
public enum AppVersion {
    /// nil outside an app bundle, as in `swift run`
    public static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// Numbers of "v1.2.3" or "1.2"; nil for any other shape
    public static func parts(_ text: String) -> [Int]? {
        let bare = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        // Overflow fails the whole tag, not one part
        let numbers = parts.map { Int($0) }
        return numbers.contains(nil) ? nil : numbers.map { $0! }
    }

    /// Missing parts count as 0: 1.1 equals 1.1.0
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = parts(candidate), let b = parts(installed) else { return false }
        let pad = { (p: [Int]) in p + Array(repeating: 0, count: 3 - p.count) }
        return pad(b).lexicographicallyPrecedes(pad(a))
    }
}
