import Foundation

/// UI language: follows the system, or a fixed choice
/// System: Korean if first preferred language, else English
public enum Language: String, CaseIterable {
    case system, english, korean
}

/// Two-language UI text: call sites pass both, `t` picks one
public enum L10n {
    private static let lock = NSLock()
    private static var current = Language.system

    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    static func isKorean(_ language: Language, preferred: [String] = Locale.preferredLanguages) -> Bool {
        switch language {
        case .english: return false
        case .korean: return true
        case .system: return preferred.first?.hasPrefix("ko") ?? false
        }
    }

    public static func t(_ english: String, _ korean: String) -> String {
        isKorean(language) ? korean : english
    }

    /// The language text shows in; system resolved
    public static var shown: Language { isKorean(language) ? .korean : .english }

    // MARK: String catalog
    // Text in `<code>.lproj/Localizable.strings`, the English text as key
    // Tables are read from the app bundle: SwiftPM resource bundles do not reach
    // the receiver, which is built with swiftc and no resource accessor

    private struct Catalog {
        var bundle: Bundle
        /// Codes with a folder in `bundle`
        var available: [String]
        /// nil: no folder for that code; English has none, its key is the text
        var tables: [String: Bundle?] = [:]

        init(bundle: Bundle) {
            self.bundle = bundle
            available = bundle.localizations.filter { $0 != "Base" }
        }
    }

    private static var catalog = Catalog(bundle: .main)

    /// Where the `.lproj` folders are; tests point it at the source tree
    public static var catalogBundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return catalog.bundle }
        set { lock.lock(); catalog = Catalog(bundle: newValue); lock.unlock() }
    }

    /// The table code for `language`; "en" when none is offered
    /// English is always offered: without it, ["en-US", "ko-KR"] would pick ko
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
    /// Arguments fill its placeholders (%@ String, %lld Int); none: used as is
    public static func s(_ key: String, _ args: CVarArg...) -> String {
        let text = lookup(key, language: language)
        return args.isEmpty ? text : String(format: text, arguments: args)
    }

    static func lookup(_ key: String, language: Language, preferred: [String] = Locale.preferredLanguages) -> String {
        lock.lock(); defer { lock.unlock() }
        let code = self.code(for: language, available: catalog.available, preferred: preferred)
        let table: Bundle?
        if let cached = catalog.tables[code] {
            table = cached
        } else {
            table = catalog.bundle.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
            catalog.tables.updateValue(table, forKey: code)
        }
        return table?.localizedString(forKey: key, value: key, table: nil) ?? key
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
