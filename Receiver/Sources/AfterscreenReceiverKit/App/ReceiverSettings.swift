import Combine
import Foundation
import AfterscreenCore

/// Receiver preferences in UserDefaults
/// Login item is a LaunchAgent: works on macOS 10.15
public final class ReceiverSettings: ObservableObject {
    public enum Accept: String, CaseIterable {
        case any
        /// Thunderbolt, USB and Ethernet; Wi-Fi is refused
        case wired
    }

    /// Where the stream shows
    public enum Presentation: String, CaseIterable {
        /// Own full-screen Space; Control-arrow switches to the iMac's desktops
        case space
        /// Above everything, menu bar and Dock included
        case cover
    }

    /// Power-on and power-off effect
    public enum Effect: String, CaseIterable {
        /// Tiles open centre-out, close corners-in
        case tiles
        /// A picture tube switching on and off
        case crt
        case none
    }

    /// Screen corner the HUD snaps to
    public enum HUDCorner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public enum OnDisconnect: String, CaseIterable {
        case showDesktop
        case sleepDisplay
    }

    /// A screen picked in the settings
    /// Name kept to show it while unplugged
    public struct ChosenDisplay: Equatable {
        public var key: String
        public var name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    private enum Key {
        static let accept = "accept"
        static let onDisconnect = "onDisconnect"
        static let language = "language"
        static let presentation = "presentation"
        static let effect = "effect"
        static let hudCorner = "hudCorner"
        static let hudCollapsed = "hudCollapsed"
        static let pairedOnly = "pairedOnly"
        static let deviceID = "deviceID"
        static let display = "display"
        static let displayName = "displayName"
        static let matchPanelMode = "matchPanelMode"
    }

    /// Networks need a paired Mac; point-to-point cables never do
    @Published public var pairedOnly: Bool {
        didSet { defaults.set(pairedOnly, forKey: Key.pairedOnly) }
    }
    /// This receiver's lasting identity, made once
    public let deviceID: String

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
    /// nil: automatic, this Mac's panel first
    /// Applies from the next connection
    @Published public var display: ChosenDisplay? {
        didSet {
            defaults.set(display?.key, forKey: Key.display)
            defaults.set(display?.name, forKey: Key.displayName)
        }
    }
    /// Scaled resolutions switch to the panel's own while streaming
    @Published public var matchPanelMode: Bool {
        didSet { defaults.set(matchPanelMode, forKey: Key.matchPanelMode) }
    }
    /// Applies from the next connection
    @Published public var effect: Effect {
        didSet { defaults.set(effect.rawValue, forKey: Key.effect) }
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
        accept = defaults.enumValue(forKey: Key.accept, default: .any)
        onDisconnect = defaults.enumValue(forKey: Key.onDisconnect, default: .showDesktop)
        language = defaults.enumValue(forKey: Key.language, default: .system)
        presentation = defaults.enumValue(forKey: Key.presentation, default: .space)
        effect = defaults.enumValue(forKey: Key.effect, default: .tiles)
        hudCorner = defaults.enumValue(forKey: Key.hudCorner, default: .topRight)
        hudCollapsed = defaults.bool(forKey: Key.hudCollapsed)
        pairedOnly = defaults.object(forKey: Key.pairedOnly) as? Bool ?? true
        display = defaults.string(forKey: Key.display).map { ChosenDisplay(key: $0, name: defaults.string(forKey: Key.displayName) ?? $0) }
        matchPanelMode = defaults.object(forKey: Key.matchPanelMode) as? Bool ?? true
        if let id = defaults.string(forKey: Key.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.deviceID)
        }
        L10n.language = language
    }

    public func accepts(_ link: LinkKind) -> Bool {
        accept == .any || link != .wifi
    }

    /// Starts the app at login in the user's GUI session
    /// Located by bundle id, independent of install path
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
