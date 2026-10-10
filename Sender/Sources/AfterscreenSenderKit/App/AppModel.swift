import AppKit
import Combine
import CoreGraphics
import Network
import AfterscreenCore

/// Menu bar popover state; connects by hand or automatically
public final class AppModel: ObservableObject {
    @Published public var receivers: [DiscoveredReceiver] = []
    @Published public var snapshot = SenderSnapshot()
    @Published public var activeReceiver: String?
    @Published public var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published public var lastMessage: String?
    /// Latest quality test, kept after it ends
    @Published public var testReport: QualityTest.Report?
    @Published public var isTesting = false
    /// Links that reach each receiver now, fastest first
    @Published public private(set) var links: [String: [LinkKind]] = [:]
    /// Receiver panel brightness
    /// After a change: slider value until the receiver reports it
    @Published public private(set) var brightness: Double?
    private var brightnessSetAt = 0.0

    public let settings: SenderSettings
    private var session: SenderSession?
    private let discovery = Discovery()
    private var auto = AutoConnect()
    private var retry: DispatchWorkItem?
    /// Reconnect target once the replaced session ends
    private var reconnect: DiscoveredReceiver?
    private let paths = NWPathMonitor()
    private var cancellables: Set<AnyCancellable> = []

    public init(settings: SenderSettings = SenderSettings()) {
        self.settings = settings
        discovery.onChange = { [weak self] list in
            self?.receivers = list
            self?.refreshLinks()
            self?.considerAutoConnect()
        }
        discovery.start()
        // Cable plug/unplug changes which links reach a receiver
        paths.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.refreshLinks() } }
        paths.start(queue: .global(qos: .utility))
        settings.$displaySize.dropFirst().sink { [weak self] size in self?.session?.setDisplaySize(size) }.store(in: &cancellables)
        settings.$sound.dropFirst().sink { [weak self] on in self?.session?.setSound(on) }.store(in: &cancellables)
        settings.$streamResolution.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restart(L10n.t("Changing the resolution", "해상도를 바꾸는 중")) }
            .store(in: &cancellables)
        settings.$displayRole.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] role in
                self?.restart(role == .mirror ? L10n.t("Switching to mirroring", "복제로 바꾸는 중") : L10n.t("Switching to extending", "확장으로 바꾸는 중"))
            }
            .store(in: &cancellables)
        settings.$mirrorFit.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.settings.displayRole == .mirror else { return }
                self?.restart(L10n.t("Changing what the mirror fits", "복제 맞춤을 바꾸는 중"))
            }
            .store(in: &cancellables)
        // Mirror follows the main display's identity and size
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let source = self?.session?.mirrorSource, source != MirrorSource.main else { return }
            self?.restart(L10n.t("The mirrored display changed", "복제하는 디스플레이가 바뀌었습니다"))
        }
        // Text resolves at render time; language change redraws popover
        settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // Published fires before the new value is stored
        settings.$autoConnect.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.considerAutoConnect() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The link takes a moment to come back after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.considerAutoConnect() }
        }
    }

    public var isActive: Bool { session != nil }

    /// Receiver default points, else 5K's; labels display sizes
    public var panelPoints: PixelSize { snapshot.peer?.panelPoints ?? PixelSize(width: 2560, height: 1440) }

    public func connect(_ receiver: DiscoveredReceiver) {
        start(receiver, manual: true)
    }

    /// Asks each receiver on every link; popover lists answering links
    public func refreshLinks() {
        for receiver in receivers {
            RoutePlanner.routes(to: receiver) { [weak self] routes in
                DispatchQueue.main.async {
                    // Change only: rebuilt items close an open link menu
                    let kinds = RoutePlanner.kinds(routes)
                    if self?.links[receiver.name] != kinds { self?.links[receiver.name] = kinds }
                }
            }
        }
        let kept = links.filter { name, _ in receivers.contains { $0.name == name } }
        if kept != links { links = kept }
    }

    /// nil: automatic
    /// Display session on another link reconnects over the new one
    public func setLink(_ link: LinkKind?) {
        settings.link = link
        // Automatic before the links are known: no basis to switch
        guard let session = session, !isTesting, let receiver = receivers.first(where: { $0.name == activeReceiver }),
              let target = link ?? links[receiver.name]?.first, snapshot.link != target else { return }
        reconnect = receiver
        let name = link.map { LinkLabel.name($0) } ?? L10n.t("the fastest link", "가장 빠른 링크")
        session.stop(reason: L10n.t("Switching to \(name)", "\(name)(으)로 바꾸는 중"), relink: true)
    }

    /// New transfer size or display role: a new session
    private func restart(_ reason: String) {
        guard let session = session, !isTesting else { return }
        // Bonjour may drop the receiver; the session keeps its target
        reconnect = receivers.first { $0.name == activeReceiver } ?? session.target
        session.stop(reason: reason, relink: true)
    }

    private func start(_ receiver: DiscoveredReceiver, manual: Bool) {
        guard session == nil else { return }
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        guard screenRecordingGranted else {
            if manual {
                CGRequestScreenCaptureAccess()
                lastMessage = L10n.t("Allow Screen Recording for Afterscreen, then connect again",
                                     "Afterscreen에 화면 기록 권한을 허용한 뒤 다시 연결하세요")
            }
            return
        }
        if manual {
            settings.lastReceiver = receiver.name
            auto = AutoConnect()
        }
        retry?.cancel()
        let session = SenderSession(target: receiver, displaySize: settings.displaySize, link: settings.link, sound: settings.sound,
                                    deband: settings.deband, brightness: settings.brightness, resolution: settings.streamResolution,
                                    role: settings.displayRole, fit: settings.mirrorFit)
        session.onUpdate = { [weak self] s in
            guard let self = self else { return }
            self.snapshot = s
            if s.isStreaming { self.auto.streamed() }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.brightnessSetAt > 1.5, self.brightness != s.receiver?.brightness { self.brightness = s.receiver?.brightness }
        }
        session.onEnd = { [weak self, weak session] reason in
            guard let self = self else { return }
            // A stop on the iMac counts as a Disconnect here
            if session?.pausedByReceiver == true {
                self.auto.userDisconnected()
                self.reconnect = nil
            }
            self.brightness = nil
            self.session = nil
            self.activeReceiver = nil
            self.lastMessage = reason
            if let receiver = self.reconnect {
                self.reconnect = nil
                return self.start(receiver, manual: true)
            }
            self.scheduleRetry()
            self.refreshLinks()
        }
        self.session = session
        activeReceiver = receiver.name
        lastMessage = nil
        session.start()
    }

    /// Pauses automatic connection until the receiver goes away
    public func disconnect() {
        auto.userDisconnected()
        reconnect = nil
        session?.stop()
    }

    public func setBrightness(_ level: Double) {
        brightness = level
        brightnessSetAt = ProcessInfo.processInfo.systemUptime
        settings.brightness = level
        session?.setBrightness(level)
    }

    public func setDeband(_ level: Deband) {
        settings.deband = level
        session?.setDeband(level)
    }

    public func stopTest() {
        session?.stop(reason: L10n.t("Quality test stopped", "품질 테스트를 멈췄습니다"))
    }

    private func considerAutoConnect() {
        guard session == nil, CGPreflightScreenCaptureAccess(),
              let receiver = auto.target(in: receivers, last: settings.lastReceiver, enabled: settings.autoConnect) else { return }
        start(receiver, manual: false)
    }

    /// Backoff retry for dropped or failed sessions while receiver listed
    private func scheduleRetry() {
        guard settings.autoConnect else { return }
        let work = DispatchWorkItem { [weak self] in self?.considerAutoConnect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + auto.nextRetryDelay(), execute: work)
    }

    /// Needs no Screen Recording: the test streams generated frames
    public func runQualityTest(_ receiver: DiscoveredReceiver) {
        guard session == nil else { return }
        let session = SenderSession(target: receiver, purpose: .qualityTest, link: settings.link, deband: settings.deband)
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

    public var statusTitle: String { StatusTitle.text(snapshot, stats: settings.menuBarStats) }
    public var statusIcon: NSImage { StatusIcon.image(link: StatusTitle.mark(snapshot)) }
}
