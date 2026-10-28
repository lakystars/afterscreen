import Combine
import CoreGraphics
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

    // Shared with senders, which may change them
    public typealias Presentation = ReceiverOptions.Presentation
    public typealias Effect = ReceiverOptions.Effect
    public typealias OnDisconnect = ReceiverOptions.OnDisconnect

    /// Screen corner the HUD snaps to
    public enum HUDCorner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
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

    /// Settings a sender may change; HUD state from the screen
    public func options(screens: [ReceiverDisplay], hud: Bool, editable: Bool) -> ReceiverOptions {
        let missing = display.flatMap { chosen in screens.contains { $0.key == chosen.key } ? nil : chosen.name }
        return ReceiverOptions(editable: editable, hud: hud, presentation: presentation,
                               screens: screens.map { ReceiverOptions.Screen(key: $0.key, name: $0.name, pixels: $0.pixels) },
                               screen: display?.key, missingScreen: missing, matchPanelMode: matchPanelMode, effect: effect,
                               onDisconnect: onDisconnect, launchAtLogin: launchAtLogin)
    }

    /// A trusted sender's edit; HUD left to the caller
    public func apply(_ change: ReceiverOptionsChange, screens: [ReceiverDisplay]) {
        if let v = change.presentation { presentation = v }
        if let key = change.screen {
            if key.isEmpty {
                display = nil
            } else if let d = screens.first(where: { $0.key == key }) {
                display = ChosenDisplay(key: d.key, name: d.name)
            }
        }
        if let v = change.matchPanelMode { matchPanelMode = v }
        if let v = change.effect { effect = v }
        if let v = change.onDisconnect { onDisconnect = v }
        if let v = change.launchAtLogin, v != launchAtLogin { launchAtLogin = v }
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

/// What a stream's window opens with; fixed until it closes
struct StreamWindowSettings: Equatable {
    var presentation: ReceiverSettings.Presentation
    var display: CGDirectDisplayID
    var matchPanelMode: Bool

    /// The edit touched these and the window differs now
    /// A change made here waits for the next connection
    static func reopens(_ change: ReceiverOptionsChange, open: StreamWindowSettings, next: StreamWindowSettings) -> Bool {
        let touched = change.presentation != nil || change.screen != nil || change.matchPanelMode != nil
        return touched && open != next
    }
}
