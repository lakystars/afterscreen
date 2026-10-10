import Combine
import Foundation
import AfterscreenCore

/// Receiver preferences in UserDefaults; the login item is a LaunchAgent, which works on macOS 10.15
public final class ReceiverSettings: ObservableObject {
    public enum Accept: String, CaseIterable {
        case any
        /// Thunderbolt, USB and Ethernet; Wi-Fi is refused
        case wired
    }

    /// Where the stream shows
    public enum Presentation: String, CaseIterable {
        /// A full-screen Space of its own: the iMac's desktops stay a Control-arrow away
        case space
        /// Above everything, menu bar and Dock included: the iMac is only a display
        case cover
    }

    /// Screen corner the HUD snaps to
    public enum HUDCorner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public enum OnDisconnect: String, CaseIterable {
        case showDesktop
        case sleepDisplay
    }

    private enum Key {
        static let accept = "accept"
        static let onDisconnect = "onDisconnect"
        static let language = "language"
        static let presentation = "presentation"
        static let hudCorner = "hudCorner"
        static let hudCollapsed = "hudCollapsed"
    }

    public static let agentLabel = "io.github.lakystars.afterscreen.receiver"

    @Published public var accept: Accept {
        didSet { defaults.set(accept.rawValue, forKey: Key.accept) }
    }
    @Published public var onDisconnect: OnDisconnect {
        didSet { defaults.set(onDisconnect.rawValue, forKey: Key.onDisconnect) }
    }
    @Published public var presentation: Presentation {
        didSet { defaults.set(presentation.rawValue, forKey: Key.presentation) }
    }
    public var hudCorner: HUDCorner {
        didSet { defaults.set(hudCorner.rawValue, forKey: Key.hudCorner) }
    }
    /// The HUD folded to one line
    public var hudCollapsed: Bool {
        didSet { defaults.set(hudCollapsed, forKey: Key.hudCollapsed) }
    }
    @Published public var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L10n.language = language
        }
    }

    private let defaults: UserDefaults
    private let agentFile: URL
    private let bundleID: String

    public init(defaults: UserDefaults = .standard,
                agentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                bundleID: String = Bundle.main.bundleIdentifier ?? ReceiverSettings.agentLabel) {
        self.defaults = defaults
        agentFile = agentDirectory.appendingPathComponent(ReceiverSettings.agentLabel + ".plist")
        self.bundleID = bundleID
        accept = Accept(rawValue: defaults.string(forKey: Key.accept) ?? "") ?? .any
        onDisconnect = OnDisconnect(rawValue: defaults.string(forKey: Key.onDisconnect) ?? "") ?? .showDesktop
        language = Language(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        presentation = Presentation(rawValue: defaults.string(forKey: Key.presentation) ?? "") ?? .space
        hudCorner = HUDCorner(rawValue: defaults.string(forKey: Key.hudCorner) ?? "") ?? .topRight
        hudCollapsed = defaults.bool(forKey: Key.hudCollapsed)
        L10n.language = language
    }

    public func accepts(_ link: LinkKind) -> Bool {
        accept == .any || link != .wifi
    }

    /// Starts the app in the user's GUI session at login, found by bundle id wherever it lives
    public var launchAtLogin: Bool {
        get { FileManager.default.fileExists(atPath: agentFile.path) }
        set {
            objectWillChange.send()
            guard newValue else {
                try? FileManager.default.removeItem(at: agentFile)
                return
            }
            let plist: [String: Any] = [
                "Label": ReceiverSettings.agentLabel,
                "ProgramArguments": ["/usr/bin/open", "-b", bundleID],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentFile)
        }
    }
}
