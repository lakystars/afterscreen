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

    public enum OnDisconnect: String, CaseIterable {
        case showDesktop
        case sleepDisplay
    }

    private enum Key {
        static let accept = "accept"
        static let onDisconnect = "onDisconnect"
    }

    static let agentLabel = "io.github.lakystars.afterscreen.receiver"

    @Published public var accept: Accept {
        didSet { defaults.set(accept.rawValue, forKey: Key.accept) }
    }
    @Published public var onDisconnect: OnDisconnect {
        didSet { defaults.set(onDisconnect.rawValue, forKey: Key.onDisconnect) }
    }

    private let defaults: UserDefaults
    private let agentFile: URL
    private let executable: String

    public init(defaults: UserDefaults = .standard,
                agentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) {
        self.defaults = defaults
        agentFile = agentDirectory.appendingPathComponent(ReceiverSettings.agentLabel + ".plist")
        self.executable = executable
        accept = Accept(rawValue: defaults.string(forKey: Key.accept) ?? "") ?? .any
        onDisconnect = OnDisconnect(rawValue: defaults.string(forKey: Key.onDisconnect) ?? "") ?? .showDesktop
    }

    public func accepts(_ link: LinkKind) -> Bool {
        accept == .any || link.isWired
    }

    /// Starts the app in the user's GUI session at login
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
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentFile)
        }
    }
}
