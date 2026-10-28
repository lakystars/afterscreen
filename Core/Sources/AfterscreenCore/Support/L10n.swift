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

    /// Picker label for each choice, in its own language
    public static func name(_ language: Language) -> String {
        switch language {
        case .system: return t("System", "시스템 설정")
        case .english: return "English"
        case .korean: return "한국어"
        }
    }
}
