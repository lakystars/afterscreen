import Foundation

/// UI language: follows the system, or a fixed choice
/// System: first preferred language offered, else English
public enum Language: String, CaseIterable {
    case system, english, korean
}

/// UI text: `t` takes both languages, `s` reads the tables
/// `t`, `s` and `shown` share one resolved table code
public enum L10n {
    private static let lock = NSLock()
    private static var current = Language.system
    /// `current` resolved; cleared when the language or bundle changes
    /// System order changes apply after relaunch, like Bundle.main
    private static var resolved: String?

    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; resolved = nil; lock.unlock() }
    }

    public static func t(_ english: String, _ korean: String) -> String {
        shownCode == "ko" ? korean : english
    }

    /// The language text shows in; system resolved
    public static var shown: Language { shownCode == "ko" ? .korean : .english }

    /// Table code text shows in
    static var shownCode: String {
        lock.lock(); defer { lock.unlock() }
        return resolveLocked()
    }

    /// Caller holds `lock`; preferences are read once per change
    private static func resolveLocked() -> String {
        if let cached = resolved { return cached }
        let fresh = code(for: current, available: catalog.available)
        resolved = fresh
        return fresh
    }

    // MARK: String catalog
    // `<code>.lproj/Afterscreen.strings`, the English text as key
    // Own table: SwiftUI `Text` literals read Localizable.strings
    // Read from the app bundle, not a SwiftPM resource bundle
    // Receiver builds with swiftc: no resource accessor

    private struct Catalog {
        var bundle: Bundle
        /// Codes with a folder in `bundle`
        var available: [String]
        /// nil: no folder; English has none, keys are its text
        var tables: [String: Bundle?] = [:]

        init(bundle: Bundle) {
            self.bundle = bundle
            available = bundle.localizations.filter { $0 != "Base" }
        }
    }

    private static var catalog = Catalog(bundle: .main)

    /// Holds the `.lproj` folders; tests use the source tree
    public static var catalogBundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return catalog.bundle }
        set { lock.lock(); catalog = Catalog(bundle: newValue); resolved = nil; lock.unlock() }
    }

    /// Table code for `language`; "en" when no preference matches
    /// en always offered, else en-US users would get ko
    static func code(for language: Language, available: [String], preferred: [String] = Locale.preferredLanguages) -> String {
        switch language {
        case .english: return "en"
        case .korean: return "ko"
        case .system:
            guard !preferred.isEmpty else { return "en" }
            let offered = Array(Set(available + ["en"])).sorted()
            return Bundle.preferredLocalizations(from: offered, forPreferences: preferred).first ?? "en"
        }
    }

    /// `key` in the shown language, else `key`
    /// Arguments fill placeholders: %@ String, %lld Int
    /// Without arguments `key` is not formatted
    public static func s(_ key: String, _ args: CVarArg...) -> String {
        let text = lookup(key)
        return args.isEmpty ? text : String(format: text, arguments: args)
    }

    private static let tableName = "Afterscreen"

    private static func lookup(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let code = resolveLocked()
        let table: Bundle?
        if let cached = catalog.tables[code] {
            table = cached
        } else {
            table = catalog.bundle.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
            catalog.tables.updateValue(table, forKey: code)
        }
        return table?.localizedString(forKey: key, value: key, table: tableName) ?? key
    }

    /// Picker label for each choice, in its own language
    public static func name(_ language: Language) -> String {
        switch language {
        case .system: return t("System", "시스템 설정")
        case .english: return "English"
        case .korean: return "한국어"
        }
    }
}
