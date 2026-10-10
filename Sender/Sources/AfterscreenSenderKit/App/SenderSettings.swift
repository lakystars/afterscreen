import Combine
import Foundation
import AfterscreenCore
import ServiceManagement

/// Pixels sent: the panel's, or four fifths per axis
/// Four fifths of 5K: 4096 × 2304
/// Automatic reduces on Wi-Fi only
public enum StreamResolution: String, CaseIterable, Identifiable {
    case auto, panel, reduced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return L10n.t("Automatic", "자동")
        case .panel: return L10n.t("Panel resolution", "패널 해상도")
        case .reduced: return L10n.t("Four fifths", "4/5 해상도")
        }
    }
}

/// What the iMac shows
/// Extend: a display of its own, as macOS arranges it
/// Mirror: this Mac's main display, letterboxed to the panel
public enum DisplayRole: String, CaseIterable, Identifiable {
    case extend, mirror

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .extend: return L10n.t("Extend", "확장")
        case .mirror: return L10n.t("Mirror", "복제")
        }
    }

    public static var help: String {
        L10n.t("Extend: the iMac is a display of its own. Mirror: it shows this Mac's main display; black bars fill the rest when the shapes differ",
               "확장: iMac이 별도의 디스플레이가 됩니다. 복제: 이 Mac의 주 디스플레이를 그대로 보여 주고, 화면 비율이 다르면 남는 곳은 검게 둡니다")
    }
}

/// Mirror's shape, as macOS's "Optimize for"
/// This Mac: its own resolution, letterboxed on the iMac
/// iMac: the desktop takes the iMac's shape; this Mac letterboxes
public enum MirrorFit: String, CaseIterable, Identifiable {
    case mac, iMac

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mac: return L10n.t("This Mac", "이 Mac")
        case .iMac: return "iMac"
        }
    }

    public static var help: String {
        L10n.t("This Mac: it keeps its resolution and the iMac shows black bars where the shapes differ. iMac: the desktop takes the iMac's shape and resolution, sharp and edge to edge there; this Mac shows it with bars",
               "이 Mac: 해상도를 그대로 두고, 비율이 다르면 iMac에 검은 여백이 생깁니다. iMac: 데스크톱을 iMac의 비율과 해상도로 바꿔 iMac에 꽉 차고 선명하게 보이고, 이 Mac 화면에 여백이 생깁니다")
    }
}

/// Virtual display "looks like" size, scaled from receiver default points
public enum DisplaySize: String, CaseIterable, Identifiable {
    case larger, standard, more, most

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .larger: return L10n.t("Larger text", "큰 글자")
        case .standard: return L10n.t("Default", "기본")
        case .more: return L10n.t("More space", "더 넓게")
        case .most: return L10n.t("Most space", "가장 넓게")
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
        static let language = "language"
        static let sound = "sound"
        static let deband = "deband"
        static let streamResolution = "streamResolution"
        static let displayRole = "displayRole"
        static let mirrorFit = "mirrorFit"
    }

    @Published public var displayRole: DisplayRole {
        didSet { defaults.set(displayRole.rawValue, forKey: Key.displayRole) }
    }
    @Published public var mirrorFit: MirrorFit {
        didSet { defaults.set(mirrorFit.rawValue, forKey: Key.mirrorFit) }
    }

    @Published public var displaySize: DisplaySize {
        didSet { defaults.set(displaySize.rawValue, forKey: Key.displaySize) }
    }
    @Published public var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }
    @Published public var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L10n.language = language
        }
    }
    /// Plays this Mac's sound on the receiver; local output silent
    @Published public var sound: Bool {
        didSet { defaults.set(sound, forKey: Key.sound) }
    }
    /// Smoothing of 8-bit steps on the receiver
    @Published public var deband: Deband {
        didSet { defaults.set(Int(deband.rawValue), forKey: Key.deband) }
    }

    @Published public var streamResolution: StreamResolution {
        didSet { defaults.set(streamResolution.rawValue, forKey: Key.streamResolution) }
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
        displayRole = defaults.enumValue(forKey: Key.displayRole, default: .extend)
        mirrorFit = defaults.enumValue(forKey: Key.mirrorFit, default: .mac)
        displaySize = defaults.enumValue(forKey: Key.displaySize, default: .standard)
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        menuBarStats = defaults.bool(forKey: Key.menuBarStats)
        sound = defaults.object(forKey: Key.sound) as? Bool ?? true
        streamResolution = defaults.enumValue(forKey: Key.streamResolution, default: .auto)
        deband = (defaults.object(forKey: Key.deband) as? Int).flatMap { UInt8(exactly: $0) }.flatMap(Deband.init(rawValue:)) ?? .normal
        language = defaults.enumValue(forKey: Key.language, default: .system)
        L10n.language = language
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

/// Auto-connect target: last receiver once listed, unless user-disconnected
struct AutoConnect {
    /// Set by user Disconnect; cleared when receiver leaves the list
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

    /// 3 s, doubling to 60 s
    /// For sessions that drop or fail to start
    mutating func nextRetryDelay() -> TimeInterval {
        defer { failures += 1 }
        return min(60, 3 * pow(2, Double(failures)))
    }

    mutating func streamed() { failures = 0 }
}
