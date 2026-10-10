import Combine
import Foundation
import AfterscreenCore
import ServiceManagement

/// "Looks like" size of the virtual display around the receiver's default points
public enum DisplaySize: String, CaseIterable, Identifiable {
    case larger, standard, more, most

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .larger: return "Larger text"
        case .standard: return "Default"
        case .more: return "More space"
        case .most: return "Most space"
        }
    }

    private var scale: Double {
        switch self {
        case .larger: return 0.8
        case .standard: return 1
        case .more: return 1.125
        case .most: return 1.25
        }
    }

    /// 16:9 widths macOS offers as scaled modes
    private static let widths = [1280, 1600, 1920, 2048, 2304, 2560, 2880, 3200, 3840]

    public func points(for base: PixelSize) -> PixelSize {
        guard self != .standard, base.width > 0 else { return base }
        let want = Double(base.width) * scale
        let width = DisplaySize.widths.min { abs(Double($0) - want) < abs(Double($1) - want) } ?? base.width
        return PixelSize(width: width, height: (width * base.height / base.width + 1) / 2 * 2)
    }
}

/// Sender preferences in UserDefaults
public final class SenderSettings: ObservableObject {
    private enum Key {
        static let displaySize = "displaySize"
        static let autoConnect = "autoConnect"
        static let lastReceiver = "lastReceiver"
        static let link = "link"
        static let menuBarStats = "menuBarStats"
    }

    @Published public var displaySize: DisplaySize {
        didSet { defaults.set(displaySize.rawValue, forKey: Key.displaySize) }
    }
    @Published public var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }
    /// Frame rate and throughput next to the menu bar icon
    @Published public var menuBarStats: Bool {
        didSet { defaults.set(menuBarStats, forKey: Key.menuBarStats) }
    }
    /// Link to use; nil picks the fastest that answers
    public var link: LinkKind? {
        get { defaults.string(forKey: Key.link).flatMap(LinkKind.init(rawValue:)) }
        set {
            objectWillChange.send()
            defaults.set(newValue?.rawValue, forKey: Key.link)
        }
    }

    /// Receiver last connected by hand; the auto-connect target
    public var lastReceiver: String? {
        get { defaults.string(forKey: Key.lastReceiver) }
        set { defaults.set(newValue, forKey: Key.lastReceiver) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displaySize = DisplaySize(rawValue: defaults.string(forKey: Key.displaySize) ?? "") ?? .standard
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        menuBarStats = defaults.bool(forKey: Key.menuBarStats)
    }

    /// Login item state lives in ServiceManagement, not in the defaults
    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            _ = try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

/// When to connect without a click: the last receiver, once it is listed, unless the user disconnected from it
struct AutoConnect {
    /// Set by a user Disconnect; cleared when the receiver leaves the list
    private var paused = false
    private var failures = 0

    mutating func target(in list: [DiscoveredReceiver], last: String?, enabled: Bool) -> DiscoveredReceiver? {
        guard enabled, let last = last else { return nil }
        guard let receiver = list.first(where: { $0.name == last }) else {
            paused = false
            return nil
        }
        return paused ? nil : receiver
    }

    mutating func userDisconnected() { paused = true }

    /// 3 s, doubling to 60 s, for sessions that drop or fail to start
    mutating func nextRetryDelay() -> TimeInterval {
        defer { failures += 1 }
        return min(60, 3 * pow(2, Double(failures)))
    }

    mutating func streamed() { failures = 0 }
}
