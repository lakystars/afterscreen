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
    /// Popover's second level, in place of a settings window
    /// The popover outlives closing: its delegate resets this
    @Published public var showsSettings = false
    /// Links that reach each receiver now, fastest first
    @Published public private(set) var links: [String: [LinkKind]] = [:]
    /// Default output's volume and mute; nil when fixed, like HDMI
    @Published public private(set) var macVolume: OutputLevel?
    public let macName = ComputerName.current

    public let settings: SenderSettings
    private var session: SenderSession?
    private let discovery = Discovery()
    /// Receivers' keys, in the login keychain
    private let pairings: PairingStoring
    /// Receiver IDs with a kept key; read per list draw
    @Published public private(set) var pairedIDs: Set<String> = []
    /// Receiver showing a code, for display and test sessions alike
    @Published public private(set) var pairingWith: String?
    /// Rises with each wrong code: the code boxes shake
    @Published public private(set) var wrongCodes = 0
    private var auto = AutoConnect()
    private var retry: DispatchWorkItem?
    /// Reconnect target once the replaced session ends
    private var reconnect: DiscoveredReceiver?
    /// Uptime of the last receiver request to connect again
    private var askedBackAt = -TimeInterval.infinity
    /// Debug: the receiver tints sent blocks; off at launch
    @Published public var flashBlocks = false {
        didSet { session?.flashBlocks = flashBlocks }
    }
    /// Faster link relinks went for: kind, last try, tries
    /// Cleared when that link leaves the list
    private var fasterLink: (kind: LinkKind, at: TimeInterval, tries: Int)?
    private var fasterLinkRetry: DispatchWorkItem?
    /// Relinking for a faster link: its outcome replaces the message
    private var awaitingFasterLink: LinkKind?
    private var quitDone: (() -> Void)?
    private let systemSleep = SystemSleep()
    /// Lets a waiting sleep proceed
    private var sleepReady: (() -> Void)?
    /// Sleep or a dark wake: no display to stream
    private var screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private let paths = NWPathMonitor()
    private var volumeWatcher: OutputWatcher?
    private var cancellables: Set<AnyCancellable> = []

    public init(settings: SenderSettings = SenderSettings(),
                pairings: PairingStoring = KeychainPairingStore(service: "io.github.lakystars.afterscreen.sender.pairing")) {
        self.settings = settings
        self.pairings = pairings
        pairedIDs = Set(pairings.pairs.map(\.id))
        discovery.onChange = { [weak self] list in
            self?.receivers = list
            self?.refreshLinks()
            self?.considerAutoConnect()
        }
        discovery.start()
        // Cable plug/unplug changes which links reach a receiver
        paths.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.refreshLinks() } }
        paths.start(queue: .global(qos: .utility))
        volumeWatcher = OutputWatcher { [weak self] _ in self?.readVolume() }
        readVolume()
        settings.$displaySize.dropFirst().sink { [weak self] size in self?.session?.setDisplaySize(size) }.store(in: &cancellables)
        settings.$sound.dropFirst().sink { [weak self] on in self?.session?.setSound(on) }.store(in: &cancellables)
        settings.$brightnessFollows.combineLatest(settings.$receiverBrightness).dropFirst()
            .sink { [weak self] follows, level in self?.session?.setReceiverBrightness(follows ? nil : level) }
            .store(in: &cancellables)
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
        systemSleep.onSleep = { [weak self] ready in
            guard let self = self else { return ready() }
            self.willSleep(ready)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
        }
        // Not posted in a dark wake
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensWoke()
        }
        // A wake without screensDidWake must not leave connecting off
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
            self?.screensWoke()
        }
    }

    /// A relink held while screens slept, else auto connect
    private func screensWoke() {
        screensAsleep = false
        // The link takes a moment to come back after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.session == nil, !self.screensAsleep else { return }
            guard let receiver = self.reconnect else { return self.considerAutoConnect() }
            self.reconnect = nil
            self.start(receiver, manual: true)
        }
    }

    /// Lid closed or Sleep chosen: the iMac powers off first
    /// Sleep waits for the session's end, at most 2 s
    private func willSleep(_ ready: @escaping () -> Void) {
        screensAsleep = true
        retry?.cancel()
        reconnect = nil
        guard let session = session else { return ready() }
        sleepReady = ready
        session.close(reason: L10n.t("\(macName) went to sleep", "\(macName)이(가) 잠자기에 들어갔습니다"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.readyToSleep() }
    }

    private func readyToSleep() {
        sleepReady?()
        sleepReady = nil
    }

    public var isActive: Bool { session != nil }

    /// Receiver default points, else the last receiver's; labels display sizes
    public var panelPoints: PixelSize? { snapshot.peer?.panelPoints ?? settings.lastPanelPoints }

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
                    guard let self = self, self.links[receiver.name] != kinds else { return }
                    self.links[receiver.name] = kinds
                    // A cable may now allow connecting without pairing
                    self.considerAutoConnect()
                    if receiver.name == self.activeReceiver {
                        // Unplugged: a new plug gets fresh tries
                        if let tried = self.fasterLink?.kind, !kinds.contains(tried) { self.fasterLink = nil }
                        self.considerFasterLink()
                    }
                }
            }
        }
        let kept = links.filter { name, _ in receivers.contains { $0.name == name } }
        if kept != links { links = kept }
    }

    /// nil: automatic
    /// Display session on another link moves: seamless if possible
    public func setLink(_ link: LinkKind?) {
        settings.link = link
        // Automatic before the links are known: no basis to switch
        guard let session = session, !isTesting, !session.isClosing, !session.isHandingOver,
              let receiver = receivers.first(where: { $0.name == activeReceiver }),
              let target = link ?? links[receiver.name]?.first, snapshot.link != target else { return }
        if session.handover(to: target, done: { [weak self] in self?.handedOver($0, to: target, receiver: receiver, faster: false) }) { return }
        reconnect = receiver
        let name = link.map { LinkLabel.name($0) } ?? L10n.t("the fastest link", "가장 빠른 링크")
        session.stop(reason: L10n.t("Switching to \(name)", "\(name)(으)로 바꾸는 중"), relink: true)
    }

    /// Automatic link: a faster link mid-session takes over
    /// Checked on link changes and once streaming starts
    /// Two tries per link, 10 s apart: no relink loop
    private func considerFasterLink() {
        guard settings.link == nil, SenderSession.simulatedLinkMbps == nil, snapshot.isStreaming, let session = session,
              !isTesting, !session.isClosing, !session.isHandingOver, let receiver = receivers.first(where: { $0.name == activeReceiver }),
              let faster = RoutePlanner.upgrade(from: snapshot.link, available: links[receiver.name] ?? []) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var tries = 0
        if let last = fasterLink, last.kind == faster {
            guard last.tries < 2 else { return }
            if now < last.at + 10 { return scheduleFasterLink(after: last.at + 10 - now) }
            tries = last.tries
        }
        fasterLink = (faster, now, tries + 1)
        if session.handover(to: faster, done: { [weak self] in self?.handedOver($0, to: faster, receiver: receiver, faster: true) }) { return }
        awaitingFasterLink = faster
        reconnect = receiver
        session.stop(reason: L10n.t("Switching to the faster \(LinkLabel.name(faster))", "더 빠른 \(LinkLabel.name(faster))(으)로 바꾸는 중"), relink: true)
    }

    /// A handover's end: its message, a retry, or a relink
    private func handedOver(_ outcome: SenderSession.HandoverOutcome, to kind: LinkKind, receiver: DiscoveredReceiver, faster: Bool) {
        let name = LinkLabel.name(kind)
        switch outcome {
        case .switched:
            lastMessage = faster ? AppModel.fasterLinkOutcome(wanted: kind, got: kind) : L10n.t("Switched to \(name)", "\(name)(으)로 바꿨습니다")
        case .stayed where session?.isHandingOver == true:
            // A lost link's resume took over from it
            break
        case .stayed where faster:
            let current = LinkLabel.name(snapshot.link)
            lastMessage = L10n.t("\(name) did not take over; staying on \(current)", "\(name)(으)로 넘기지 못해 \(current)(으)로 계속 보냅니다")
            // Second try 10 s on
            considerFasterLink()
        case .stayed:
            // A chosen link: relink there as without handover
            guard let session = session, !session.isClosing else { return }
            reconnect = receiver
            session.stop(reason: L10n.t("Switching to \(name)", "\(name)(으)로 바꾸는 중"), relink: true)
        case .lost:
            // The session ends next: reconnect over the chosen link
            awaitingFasterLink = faster ? kind : nil
            reconnect = receiver
        }
    }

    static func fasterLinkOutcome(wanted: LinkKind, got: LinkKind?) -> String {
        let name = LinkLabel.name(wanted)
        return got == wanted ? L10n.t("Switched to the faster \(name)", "더 빠른 \(name)(으)로 바꿨습니다")
            : L10n.t("\(name) did not connect; on \(LinkLabel.name(got)) instead", "\(name)(으)로 연결하지 못해 \(LinkLabel.name(got))(으)로 연결했습니다")
    }

    private func scheduleFasterLink(after seconds: TimeInterval) {
        fasterLinkRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.considerFasterLink() }
        fasterLinkRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// New transfer size or display role: a new session
    private func restart(_ reason: String) {
        guard let session = session, !isTesting, !session.isClosing else { return }
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
                                    deband: settings.deband, resolution: settings.streamResolution,
                                    role: settings.displayRole, fit: settings.mirrorFit,
                                    ownBrightness: settings.brightnessFollows ? nil : settings.receiverBrightness,
                                    highRefresh: settings.highRefresh, senderID: settings.deviceID, pairings: pairings)
        session.onUpdate = { [weak self] s in
            guard let self = self else { return }
            self.follow(pairing: s.pairing, wrongCodes: s.wrongCodes)
            if let points = s.peer?.panelPoints, self.settings.lastPanelPoints != points { self.settings.lastPanelPoints = points }
            let started = s.isStreaming && !self.snapshot.isStreaming
            self.snapshot = s
            if s.isStreaming { self.auto.streamed() }
            if started {
                // A relink's reason gives way to its outcome
                self.lastMessage = self.awaitingFasterLink.map { AppModel.fasterLinkOutcome(wanted: $0, got: s.link) }
                self.awaitingFasterLink = nil
                // A link that came up while connecting
                self.considerFasterLink()
            }
        }
        session.onResume = { [weak self, weak session] resumed, from, to in
            guard let self = self else { return }
            guard resumed else {
                // Ends next: a new session over what still answers
                self.reconnect = self.receivers.first { $0.name == self.activeReceiver } ?? session?.target
                return
            }
            self.lastMessage = L10n.t("\(LinkLabel.name(from)) dropped; continuing over \(LinkLabel.name(to))",
                                      "\(LinkLabel.name(from)) 연결이 끊겨 \(LinkLabel.name(to))(으)로 이어서 보냅니다")
        }
        session.onEnd = { [weak self, weak session] reason in
            guard let self = self else { return }
            // A stop on the iMac counts as a Disconnect here
            if session?.pausedByReceiver == true {
                self.auto.userDisconnected()
                self.reconnect = nil
            }
            // Receiver gave way: at once, at most every 5 s
            let now = ProcessInfo.processInfo.systemUptime
            if session?.askedBack == true, self.reconnect == nil, now - self.askedBackAt > 5 {
                self.askedBackAt = now
                self.reconnect = self.receivers.first { $0.name == self.activeReceiver } ?? session?.target
            }
            self.session = nil
            self.activeReceiver = nil
            self.lastMessage = reason
            self.follow(pairing: nil)
            self.pairedIDs = Set(self.pairings.pairs.map(\.id))
            self.readyToSleep()
            if let done = self.quitDone {
                self.quitDone = nil
                return done()
            }
            // Screens off: held for their wake
            if let receiver = self.reconnect, !self.screensAsleep {
                self.reconnect = nil
                self.start(receiver, manual: true)
                // Shown until the new session streams
                self.lastMessage = reason
                return
            }
            self.scheduleRetry()
            self.refreshLinks()
        }
        session.flashBlocks = flashBlocks
        self.session = session
        activeReceiver = receiver.name
        lastMessage = nil
        session.start()
    }

    /// Pauses automatic connection until the receiver goes away
    public func disconnect() {
        auto.userDisconnected()
        reconnect = nil
        session?.close()
    }

    /// Quit while connected: the iMac powers off first
    /// `done` once the session has ended
    public func closeForQuit(_ done: @escaping () -> Void) {
        guard session != nil else { return done() }
        quitDone = done
        disconnect()
    }

    /// Unfollowing starts from the receiver's current level: no jump
    public func setBrightnessFollows(_ follows: Bool) {
        if !follows, let level = snapshot.receiver?.panelLevel ?? snapshot.macBrightness { settings.receiverBrightness = level }
        settings.brightnessFollows = follows
    }

    /// Connected receiver's own name, else the last one's
    public var receiverName: String { snapshot.peer?.name ?? activeReceiver ?? settings.lastReceiver ?? L10n.t("Receiver", "수신기") }

    private func readVolume() {
        let level = SystemOutput().level
        if macVolume != level { macVolume = level }
    }

    /// Default output; the receiver follows while it plays
    /// Moving it unmutes, as the menu bar's slider does
    public func setMacVolume(_ volume: Double) {
        let output = SystemOutput()
        guard let device = output.device else { return }
        output.set(OutputLevel(volume: volume, muted: false), on: device)
    }

    /// Built-in panel; following, the receiver comes along
    public func setMacBrightness(_ level: Double) {
        PanelBrightness.setBuiltIn(level)
    }

    public func setDeband(_ level: Deband) {
        settings.deband = level
        session?.setDeband(level)
    }

    public func stopTest() {
        session?.stop(reason: L10n.t("Quality test stopped", "품질 테스트를 멈췄습니다"))
    }

    /// Only where no code is needed: paired, or a cable
    /// Else each retry puts a code on that iMac's screen
    private func considerAutoConnect() {
        guard session == nil, !screensAsleep, CGPreflightScreenCaptureAccess(),
              let receiver = auto.target(in: receivers, last: settings.lastReceiver, enabled: settings.autoConnect),
              AppModel.connectsWithoutCode(paired: isPaired(receiver),
                                           route: AppModel.route(pinned: settings.link, answering: links[receiver.name])) else { return }
        start(receiver, manual: false)
    }

    static func connectsWithoutCode(paired: Bool, route: LinkKind?) -> Bool {
        paired || route == .thunderbolt || route == .usb || route == .loopback
    }

    /// A session's link: the pinned one if it answers
    static func route(pinned: LinkKind?, answering: [LinkKind]?) -> LinkKind? {
        if let pinned = pinned, answering?.contains(pinned) == true { return pinned }
        return answering?.first
    }

    /// Paired just now: the list marks the receiver
    private func follow(pairing: String?, wrongCodes: Int = 0) {
        if pairingWith != nil, pairing == nil { pairedIDs = Set(pairings.pairs.map(\.id)) }
        if pairingWith != pairing { pairingWith = pairing }
        if self.wrongCodes != wrongCodes { self.wrongCodes = wrongCodes }
    }

    public func isPaired(_ receiver: DiscoveredReceiver) -> Bool {
        !receiver.deviceID.isEmpty && pairedIDs.contains(receiver.deviceID)
    }

    /// Paired receivers by name, for Settings
    public var pairedReceivers: [(id: String, name: String)] { pairings.pairs }

    public func removePairing(_ id: String) {
        pairings.remove(id)
        pairedIDs = Set(pairings.pairs.map(\.id))
    }

    /// Main queue: the code the receiver shows
    public func submitPairingCode(_ code: String) {
        session?.submitPairingCode(code)
    }

    private var codeFileTimer: DispatchSourceTimer?

    /// Development: six digits written to `path` are typed in
    public func typePairingCodes(from path: String) {
        codeFileTimer = DispatchSource.repeating(on: .main, every: 0.5) { [weak self] in
            guard self?.pairingWith != nil,
                  let code = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), code.count == 6 else { return }
            try? FileManager.default.removeItem(atPath: path)
            self?.submitPairingCode(code)
        }
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
        // Resolution and mirroring size the typical-use stage
        let session = SenderSession(target: receiver, purpose: .qualityTest, link: settings.link, deband: settings.deband,
                                    resolution: settings.streamResolution, role: settings.displayRole, fit: settings.mirrorFit,
                                    highRefresh: settings.highRefresh, senderID: settings.deviceID, pairings: pairings)
        session.onUpdate = { [weak self] s in
            self?.follow(pairing: s.pairing, wrongCodes: s.wrongCodes)
            if let r = s.qualityTest { self?.testReport = r }
        }
        session.onEnd = { [weak self] reason in
            self?.session = nil
            self?.isTesting = false
            self?.follow(pairing: nil)
            self?.lastMessage = reason
            self?.readyToSleep()
            self?.quitDone?()
            self?.quitDone = nil
        }
        self.session = session
        testReport = QualityTest.Report(receiver: receiver.name, total: QualityTest.scales.count + 1)
        isTesting = true
        lastMessage = nil
        session.start()
    }

    public func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    public var statusTitle: String { StatusTitle.text(snapshot, stats: settings.menuBarStats) }
    public var statusIcon: NSImage { StatusIcon.image(link: StatusTitle.mark(snapshot), role: .sender) }
}
