import Combine
import Foundation
import AfterscreenCore
import ServiceManagement

/// Pixels sent: the panel's, or four fifths per axis
/// Four fifths of 5K: 4096 × 2304
/// Automatic reduces when the link is slow for the panel
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

    public static func help(mac: String, receiver: String) -> String {
        L10n.t("Extend: \(receiver) is a display of its own. Mirror: it shows \(mac)'s main display; black bars fill the rest when the shapes differ",
               "확장: \(receiver) 화면이 별도의 디스플레이가 됩니다. 복제: \(mac)의 주 디스플레이를 그대로 보여 주고, 화면 비율이 다르면 남는 곳은 검게 둡니다")
    }
}

/// Receiver Mac after Disconnect, a quit or shut down
extension ReceiverPower {
    public var title: String {
        switch self {
        case .keepOn: return L10n.t("Stays on", "켜 두기")
        case .sleep: return L10n.t("Sleeps", "잠자기")
        case .shutDown: return L10n.t("Shuts down", "시스템 종료")
        }
    }

    /// Sent with the power-off; keeping on sends none
    var request: ReceiverPower? { self == .keepOn ? nil : self }

    public static func help(mac: String) -> String {
        L10n.t("Applies when you click Disconnect, quit Afterscreen or shut down \(mac). A restart, log out, sleep or dropped link leaves the receiver on. A receiver of this version or later follows it when paired or on a Thunderbolt or USB cable. Shutting down needs Allow… in the receiver's settings; until then the receiver sleeps",
               "연결 끊기를 누를 때, Afterscreen을 종료할 때, \(mac)을(를) 시스템 종료할 때 적용됩니다. 재시동, 로그아웃, 잠자기, 링크 끊김에는 수신기를 켜 둡니다. 이 버전 이상의 수신기는 페어링됐거나 Thunderbolt·USB 케이블로 연결됐을 때 따릅니다. 시스템 종료는 수신기 설정의 허용… 버튼으로 허락해야 하며, 그 전에는 잠자기로 대신합니다")
    }
}

/// Mirror's shape, as macOS's "Optimize for"
/// mac: its own resolution, letterboxed on the receiver
/// iMac: the desktop takes the receiver's shape; the Mac letterboxes
public enum MirrorFit: String, CaseIterable, Identifiable {
    case mac, iMac

    public var id: String { rawValue }

    public func title(mac: String, receiver: String) -> String {
        self == .mac ? mac : receiver
    }

    public static func help(mac: String, receiver: String) -> String {
        L10n.t("\(mac): it keeps its resolution and \(receiver) shows black bars where the shapes differ. \(receiver): the desktop takes its shape and resolution, sharp and edge to edge there; \(mac) shows it with bars",
               "\(mac): 해상도를 그대로 두고, 비율이 다르면 \(receiver)에 검은 여백이 생깁니다. \(receiver): 데스크톱을 그 비율과 해상도로 바꿔 꽉 차고 선명하게 보이고, \(mac) 화면에 여백이 생깁니다")
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

    /// Scaled from the receiver's own points, any panel shape
    /// Widths in steps of 16; heights keep the panel's ratio
    public func points(for base: PixelSize) -> PixelSize {
        guard self != .standard, base.width > 0 else { return base }
        let width = Int((Double(base.width) * scale / 16).rounded()) * 16
        return PixelSize(width: width, height: (width * base.height / base.width + 1) / 2 * 2)
    }
}

/// Following receiver's light over this Mac's, in stops
/// 0 matches nits; -1 is half, 1 is double
public enum BrightnessOffset {
    public static let range: ClosedRange<Double> = -1...1
    /// About 3.5% either side of even
    static let snap = 0.05
    /// Slider ≈ linear^(1/2.1) on Apple built-in panels
    static let sliderGamma = 2.1

    /// Clamped; near 0 snaps to 0
    public static func snapped(_ stops: Double) -> Double {
        guard stops.isFinite, abs(stops) >= snap else { return 0 }
        return min(range.upperBound, max(range.lowerBound, stops))
    }

    /// Factor on the nits sent
    public static func gain(_ stops: Double) -> Double { pow(2, stops) }

    /// Slider level for a receiver matched without nits
    public static func level(_ level: Double, stops: Double) -> Double {
        min(1, max(0, level * pow(2, stops / sliderGamma)))
    }

    /// "+20%", "−50%", "0%"
    public static func label(_ stops: Double) -> String {
        let percent = Int(((gain(stops) - 1) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : percent < 0 ? "−\(-percent)%" : "0%"
    }
}

/// Sender preferences in UserDefaults
public final class SenderSettings: ObservableObject {
    private enum Key {
        static let displaySize = "displaySize"
        static let autoConnect = "autoConnect"
        static let lastReceiver = "lastReceiver"
        static let lastPanelPoints = "lastPanelPoints"
        static let link = "link"
        static let menuBarStats = "menuBarStats"
        static let language = "language"
        static let sound = "sound"
        static let deband = "deband"
        static let streamResolution = "streamResolution"
        static let highRefresh = "highRefresh"
        static let displayRole = "displayRole"
        static let deviceID = "deviceID"
        static let mirrorFit = "mirrorFit"
        static let brightnessFollows = "brightnessFollows"
        static let receiverBrightness = "receiverBrightness"
        static let brightnessOffsets = "brightnessOffsets"
        static let endPower = "endPower"
    }

    /// This Mac's lasting identity, made once; receivers pair with it
    public let deviceID: String

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

    /// Receiver panel follows this Mac's; off, it keeps `receiverBrightness`
    @Published public var brightnessFollows: Bool {
        didSet { defaults.set(brightnessFollows, forKey: Key.brightnessFollows) }
    }
    /// Receiver panel's own slider level, while not following
    @Published public var receiverBrightness: Double {
        didSet { defaults.set(receiverBrightness, forKey: Key.receiverBrightness) }
    }
    /// `BrightnessOffset` stops by receiver ID; panels age differently
    @Published public private(set) var brightnessOffsets: [String: Double] {
        didSet { defaults.set(brightnessOffsets, forKey: Key.brightnessOffsets) }
    }

    public func brightnessOffset(for receiverID: String) -> Double {
        brightnessOffsets[receiverID] ?? 0
    }

    public func setBrightnessOffset(_ stops: Double, for receiverID: String) {
        let snapped = BrightnessOffset.snapped(stops)
        // Drags inside the snap repeat 0: no republish
        guard snapped != brightnessOffset(for: receiverID) else { return }
        brightnessOffsets[receiverID] = snapped == 0 ? nil : snapped
    }

    @Published public var streamResolution: StreamResolution {
        didSet { defaults.set(streamResolution.rawValue, forKey: Key.streamResolution) }
    }

    /// Experiment: 120 fps on Thunderbolt if the encoder keeps up
    @Published public var highRefresh: Bool {
        didSet { defaults.set(highRefresh, forKey: Key.highRefresh) }
    }

    /// Receiver Mac when a session ends on purpose
    @Published public var endPower: ReceiverPower {
        didSet { defaults.set(endPower.rawValue, forKey: Key.endPower) }
    }

    /// Frame rate and throughput next to the menu bar icon
    @Published public var menuBarStats: Bool {
        didSet { defaults.set(menuBarStats, forKey: Key.menuBarStats) }
    }
    /// Link to use; nil picks the fastest that answers
    public var link: LinkKind? {
        get { SenderSettings.launchLink ?? defaults.string(forKey: Key.link).flatMap(LinkKind.init(rawValue:)) }
        set {
            objectWillChange.send()
            SenderSettings.launchLink = nil
            defaults.set(newValue?.rawValue, forKey: Key.link)
        }
    }

    /// Receiver last connected by hand; the auto-connect target
    public var lastReceiver: String? {
        get { defaults.string(forKey: Key.lastReceiver) }
        set { defaults.set(newValue, forKey: Key.lastReceiver) }
    }

    /// Last receiver's default points, for size labels before connecting
    public var lastPanelPoints: PixelSize? {
        get {
            let wh = (defaults.array(forKey: Key.lastPanelPoints) as? [Int]) ?? []
            return wh.count == 2 ? PixelSize(width: wh[0], height: wh[1]) : nil
        }
        set { defaults.set(newValue.map { [$0.width, $0.height] }, forKey: Key.lastPanelPoints) }
    }

    /// Development: --link for this launch only, never saved
    /// Outer nil: no override; inner nil: automatic
    public static var launchLink: LinkKind??

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayRole = defaults.enumValue(forKey: Key.displayRole, default: .extend)
        if let id = defaults.string(forKey: Key.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.deviceID)
        }
        mirrorFit = defaults.enumValue(forKey: Key.mirrorFit, default: .mac)
        displaySize = defaults.enumValue(forKey: Key.displaySize, default: .standard)
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        menuBarStats = defaults.bool(forKey: Key.menuBarStats)
        sound = defaults.object(forKey: Key.sound) as? Bool ?? true
        streamResolution = defaults.enumValue(forKey: Key.streamResolution, default: .auto)
        highRefresh = defaults.bool(forKey: Key.highRefresh)
        deband = (defaults.object(forKey: Key.deband) as? Int).flatMap { UInt8(exactly: $0) }.flatMap(Deband.init(rawValue:)) ?? .normal
        brightnessFollows = defaults.object(forKey: Key.brightnessFollows) as? Bool ?? true
        receiverBrightness = defaults.object(forKey: Key.receiverBrightness) as? Double ?? 0.5
        // Per entry: one bad value drops only itself
        brightnessOffsets = (defaults.dictionary(forKey: Key.brightnessOffsets) ?? [:])
            .compactMapValues { ($0 as? NSNumber).map { BrightnessOffset.snapped($0.doubleValue) } }.filter { $0.value != 0 }
        endPower = defaults.enumValue(forKey: Key.endPower, default: .keepOn)
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
