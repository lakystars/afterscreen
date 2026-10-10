import AppKit
import Combine
import CoreGraphics
import AfterscreenCore

/// UI state for the menu bar popover; connects by hand or automatically
public final class AppModel: ObservableObject {
    @Published public var receivers: [DiscoveredReceiver] = []
    @Published public var snapshot = SenderSnapshot()
    @Published public var activeReceiver: String?
    @Published public var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published public var lastMessage: String?
    /// Latest quality test, kept after it ends
    @Published public var testReport: QualityTest.Report?
    @Published public var isTesting = false
    /// Receiver panel brightness; after a change, the slider's value until the receiver reports it
    @Published public private(set) var brightness: Double?
    private var brightnessSetAt = 0.0

    public let settings: SenderSettings
    private var session: SenderSession?
    private let discovery = Discovery()
    private var auto = AutoConnect()
    private var retry: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    public init(settings: SenderSettings = SenderSettings()) {
        self.settings = settings
        discovery.onChange = { [weak self] list in
            self?.receivers = list
            self?.considerAutoConnect()
        }
        discovery.start()
        settings.$displaySize.dropFirst().sink { [weak self] size in self?.session?.setDisplaySize(size) }.store(in: &cancellables)
        // Published fires before the new value is stored
        settings.$autoConnect.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.considerAutoConnect() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The link takes a moment to come back after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.considerAutoConnect() }
        }
    }

    public var isActive: Bool { session != nil }

    /// The receiver's default points, else 5K's, for labelling display sizes
    public var panelPoints: PixelSize { snapshot.peer?.panelPoints ?? PixelSize(width: 2560, height: 1440) }

    public func connect(_ receiver: DiscoveredReceiver) {
        start(receiver, manual: true)
    }

    private func start(_ receiver: DiscoveredReceiver, manual: Bool) {
        guard session == nil else { return }
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        guard screenRecordingGranted else {
            if manual {
                CGRequestScreenCaptureAccess()
                lastMessage = "Allow Screen Recording for Afterscreen, then connect again"
            }
            return
        }
        if manual {
            settings.lastReceiver = receiver.name
            auto = AutoConnect()
        }
        retry?.cancel()
        let session = SenderSession(target: receiver, displaySize: settings.displaySize)
        session.onUpdate = { [weak self] s in
            guard let self = self else { return }
            self.snapshot = s
            if s.isStreaming { self.auto.streamed() }
            if ProcessInfo.processInfo.systemUptime - self.brightnessSetAt > 1.5, self.brightness != s.receiver?.brightness {
                self.brightness = s.receiver?.brightness
            }
        }
        session.onEnd = { [weak self] reason in
            guard let self = self else { return }
            self.brightness = nil
            self.session = nil
            self.activeReceiver = nil
            self.lastMessage = reason
            self.scheduleRetry()
        }
        self.session = session
        activeReceiver = receiver.name
        lastMessage = nil
        session.start()
    }

    /// Pauses automatic connection until the receiver goes away
    public func disconnect() {
        auto.userDisconnected()
        session?.stop()
    }

    public func setBrightness(_ level: Double) {
        brightness = level
        brightnessSetAt = ProcessInfo.processInfo.systemUptime
        session?.setBrightness(level)
    }

    public func stopTest() {
        session?.stop(reason: "Quality test stopped")
    }

    private func considerAutoConnect() {
        guard session == nil, CGPreflightScreenCaptureAccess(),
              let receiver = auto.target(in: receivers, last: settings.lastReceiver, enabled: settings.autoConnect) else { return }
        start(receiver, manual: false)
    }

    /// A dropped or failed session retries with backoff while the receiver is listed
    private func scheduleRetry() {
        guard settings.autoConnect else { return }
        let work = DispatchWorkItem { [weak self] in self?.considerAutoConnect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + auto.nextRetryDelay(), execute: work)
    }

    /// Needs no Screen Recording: the test streams generated frames
    public func runQualityTest(_ receiver: DiscoveredReceiver) {
        guard session == nil else { return }
        let session = SenderSession(target: receiver, purpose: .qualityTest)
        session.onUpdate = { [weak self] s in
            if let r = s.qualityTest { self?.testReport = r }
        }
        session.onEnd = { [weak self] reason in
            self?.session = nil
            self?.isTesting = false
            self?.lastMessage = reason
        }
        self.session = session
        testReport = QualityTest.Report(receiver: receiver.name, total: QualityTest.scales.count)
        isTesting = true
        lastMessage = nil
        session.start()
    }

    public func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Status item text: link glyph, fps and throughput while streaming
    public var statusTitle: String {
        guard snapshot.isStreaming else { return "▭" }
        return "▭ \(LinkLabel.glyph(snapshot.link)) \(Int(snapshot.sentFPS.rounded()))fps · \(Format.compactGbps(snapshot.throughputBitsPerSecond))"
    }
}
