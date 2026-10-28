import AppKit
import AfterscreenCore
import Combine
import SwiftUI

/// This Mac once a session ends
enum AfterSession: Equatable {
    case nothing, sleepDisplay, sleep, shutDown

    /// Only after a stream: early failures retry
    /// The sender's request outranks the display setting
    static func action(streamed: Bool, relinking: Bool, stoppedHere: Bool, request: ReceiverPower?,
                       onDisconnect: ReceiverSettings.OnDisconnect) -> AfterSession {
        guard streamed, !relinking, !stoppedHere else { return .nothing }
        switch request {
        case .sleep?: return .sleep
        case .shutDown?: return .shutDown
        case .keepOn?, nil: return onDisconnect == .sleepDisplay ? .sleepDisplay : .nothing
        }
    }
}

/// Menu bar app: Bonjour advertising, one sender at a time
public final class ReceiverAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NetServiceDelegate {
    private var statusItem: NSStatusItem!
    private var listener: Listener?
    private var service: NetService?
    private var session: ReceiverSession?
    private var screen: ReceiverScreen?
    /// Development: `--panel` size and scale reported instead
    private var panelOverride: (pixels: PixelSize, scale: Int?)?
    private let windowed = CommandLine.arguments.contains("--windowed")
    private var cancellables: Set<AnyCancellable> = []
    /// Published record; set again only when it changes
    private var advertised: [String: Data] = [:]
    /// A screen gone a moment: a waking monitor drops out too
    private var screenCheck: DispatchWorkItem?
    private var terminateSignal: DispatchSourceSignal?
    private var screenSignal: DispatchSourceSignal?
    /// Keep first: sets UI language used by later properties
    private let settings = ReceiverSettings()
    /// Paired Macs' keys, in the login keychain
    private let pairings = KeychainPairingStore(service: "io.github.lakystars.afterscreen.receiver.pairing")
    /// Network guesses; cables count apart
    /// LAN guesses cannot lock out a cabled Mac
    private let pairingLimiter = PairingLimiter()
    private let cablePairingLimiter = PairingLimiter()
    private let codeWindow = PairingCodeWindow()
    private var lastSummary = L10n.t("No session yet", "아직 연결한 적 없음")
    private var stateLine = L10n.t("Starting…", "시작하는 중…")

    /// Shown localized; logged in English for scripts waiting on it
    private func state(_ english: String, _ korean: String) {
        stateLine = L10n.t(english, korean)
        FileHandle.standardError.write(Data("[receiver] \(english)\n".utf8))
    }
    private var startedAt: Date?
    private var settingsWindow: NSWindow?
    /// Session stopped on this Mac: display stays on
    private var stoppedHere = false

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Default SIGTERM exits without applicationWillTerminate
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        terminateSignal = terminate
        // `kill -USR2 <pid>`: this app's windows to /tmp/afterscreen-screen.png
        // SSH captures miss app windows; an app may capture its own
        signal(SIGUSR2, SIG_IGN)
        let screenshot = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        screenshot.setEventHandler { ReceiverAppDelegate.saveScreen() }
        screenshot.resume()
        screenSignal = screenshot
        let name = ComputerName.current
        // Development: report another panel, e.g. --panel 2880x1800@2
        // Scale after "@"; the screen's when left out
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--panel"), i + 1 < args.count {
            let spec = args[i + 1].split(separator: "@")
            let wh = spec[0].split(separator: "x").compactMap { Int($0) }
            if wh.count == 2 { panelOverride = (PixelSize(width: wh[0], height: wh[1]), spec.count > 1 ? Int(spec[1]) : nil) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        showStatus(link: nil)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        screen = ReceiverScreen(windowed: windowed, display: target()?.id ?? CGMainDisplayID())
        if let gpu = screen?.gpuName { FileHandle.standardError.write(Data("[receiver] Drawing on \(gpu)\n".utf8)) }
        if let peak = screen?.panelPeakNits { FileHandle.standardError.write(Data("[receiver] Panel peak \(Int(peak.rounded())) nits\n".utf8)) }
        screen?.onExitRequest = { [weak self] in self?.stopStreaming() }
        screen?.onSettingsRequest = { [weak self] in self?.openSettings(overStream: true) }
        screen?.onRelinkTimeout = { [weak self] in
            guard let self = self else { return }
            self.apply(AfterSession.action(streamed: true, relinking: false, stoppedHere: false, request: nil, onDisconnect: self.settings.onDisconnect))
        }
        screen?.hudContent = { [weak self] in self?.hudContent() }
        screen?.hudPlacement = (settings.hudCorner, settings.hudCollapsed)
        screen?.onHUDChange = { [weak self] corner, collapsed in
            self?.settings.hudCorner = corner
            self?.settings.hudCollapsed = collapsed
        }
        guard screen != nil else {
            state("Metal is unavailable on \(ComputerName.current)", "\(ComputerName.current)에서는 Metal을 쓸 수 없습니다")
            return
        }
        do {
            let listener = try Listener()
            listener.onAccept = { [weak self] c in DispatchQueue.main.async { self?.accept(c) } }
            listener.start()
            self.listener = listener
            publish(port: listener.port, name: name)
            state("Waiting for a sender", "송신기를 기다리는 중")
            watchScreens()
        } catch {
            state("Cannot listen: \(error)", "연결을 받을 수 없습니다: \(error)")
        }
    }

    /// Quit mid-stream: the iMac gets its own volume back
    /// SIGTERM, as from `kill`, quits through here too
    public func applicationWillTerminate(_ notification: Notification) {
        screen?.restoreOutput()
    }

    private func publish(port: UInt16, name: String) {
        let service = NetService(domain: "local.", type: AfterscreenProtocol.bonjourType + ".", name: name, port: Int32(port))
        service.delegate = self
        self.service = service
        advertise()
        service.publish()
    }

    /// Model and the chosen screen's size, as senders list them
    private func advertise() {
        let hardware = welcome(for: target())
        let txt: [String: Data] = [
            "model": Data(hardware.marketingName.utf8),
            "panel": Data("\(hardware.panelPixels.width)x\(hardware.panelPixels.height)".utf8),
            "id": Data(settings.deviceID.utf8),
        ]
        guard txt != advertised else { return }
        advertised = txt
        service?.setTXTRecord(NetService.data(fromTXTRecord: txt))
    }

    /// The screen a session would show on now
    private func target() -> ReceiverDisplay? {
        DisplayChoice.pick(ReceiverDisplay.connected(), saved: settings.display?.key)
    }

    /// Read per connection: screens come and go
    private func welcome(for display: ReceiverDisplay?) -> Welcome {
        let id = display?.id ?? CGMainDisplayID()
        var hardware = HardwareInfo.welcome(name: ComputerName.current, display: id, switching: settings.matchPanelMode && !windowed)
        if let o = panelOverride {
            hardware.panelPixels = o.pixels
            hardware.panelPoints = HardwareInfo.points(forPanel: o.pixels, scale: o.scale ?? HardwareInfo.backingScale(id))
        }
        return hardware
    }

    /// Screens plugged, unplugged or rearranged; a new choice
    /// A session whose screen left ends; the sender reconnects
    private func watchScreens() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.advertise()
                self.screenCheck?.cancel()
                let check = DispatchWorkItem { [weak self] in self?.endIfScreenLeft() }
                self.screenCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
            }
            .store(in: &cancellables)
        settings.$display.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.advertise() }
            .store(in: &cancellables)
    }

    /// Other screens stay on: no display sleep as for a disconnect
    private func endIfScreenLeft() {
        guard let session = session, let id = screen?.display,
              !ReceiverDisplay.connected().contains(where: { $0.id == id }) else { return }
        stoppedHere = true
        session.stop(reason: L10n.t("The screen was disconnected", "화면 연결이 끊겼습니다"))
    }

    /// Thunderbolt or USB with packets on that interface
    /// Not via Wi-Fi: the peer must answer on the cable
    private static func isCable(_ c: Connection, _ link: LinkKind) -> Bool {
        let local = c.localInterfaceName
        return (link == .thunderbolt || link == .usb) && local != nil && c.peerInterfaceName == local
    }

    private func refuse(_ connection: Connection, _ reason: String) {
        connection.send(.bye, json: Bye(reason: reason))
        connection.closeAfterFlush(reason: reason)
    }

    private func accept(_ connection: Connection) {
        // Resume, side channel or successor: its first message decides
        if let session = session { return session.offerChannel(connection) }
        guard let screen = screen else { return refuse(connection, L10n.t("Receiver display is unavailable", "수신기 화면을 쓸 수 없습니다")) }
        let local = connection.localInterfaceName
        let link = local.map { LinkClassifier.classify(LinkClassifier.facts(for: $0)) } ?? .unsupported
        guard settings.accepts(link) else { return refuse(connection, L10n.t("This receiver accepts Thunderbolt, USB and Ethernet only",
                                                                              "이 수신기는 Thunderbolt, USB, 이더넷 연결만 받습니다")) }
        screen.presentation = settings.presentation
        screen.effect = settings.effect
        let display = target()
        screen.display = display?.id ?? CGMainDisplayID()
        screen.matchPanelMode = settings.matchPanelMode
        // A point-to-point cable is proof enough; anything else pairs
        // Unclassified links pair too: fail closed
        let cable = ReceiverAppDelegate.isCable(connection, link)
        // Loopback skips pairing; power still needs a key
        let open = cable || link == .loopback
        let auth = ReceiverAuth(receiverID: settings.deviceID, required: settings.pairedOnly && !open,
                                store: pairings, limiter: open ? cablePairingLimiter : pairingLimiter) { [weak self] code, sender in
            guard let self = self else { return }
            guard let code = code else { return self.codeWindow.hide() }
            // Development: tests read the code from the log
            if ProcessInfo.processInfo.environment["AFTERSCREEN_LOG_PAIRING_CODE"] != nil {
                FileHandle.standardError.write(Data("[receiver] Pairing code \(code)\n".utf8))
            }
            self.state("Pairing with \(sender)", "\(sender)와(과) 페어링 중")
            self.codeWindow.show(code: code, sender: sender, on: display?.screen)
        }
        let session = ReceiverSession(connection: connection, hardware: welcome(for: display), display: screen, auth: auth)
        session.cable = cable
        // A handover's link, judged as a new session's would be
        // Settings as this session started: read off main
        let acceptsWiFi = settings.accepts(.wifi), pairedOnly = settings.pairedOnly
        session.admission = { c in
            let local = c.localInterfaceName
            let link = local.map { LinkClassifier.classify(LinkClassifier.facts(for: $0)) } ?? .unsupported
            guard link != .wifi || acceptsWiFi else {
                return .refused(L10n.t("This receiver accepts Thunderbolt, USB and Ethernet only", "이 수신기는 Thunderbolt, USB, 이더넷 연결만 받습니다"))
            }
            return ReceiverAppDelegate.isCable(c, link) || link == .loopback || !pairedOnly ? .open : .pairing
        }
        session.onHandover = { [weak self, weak session] c in
            let link = c.localInterfaceName.map { LinkClassifier.classify(LinkClassifier.facts(for: $0)) } ?? .unsupported
            session?.linkChanged(to: link)
            session?.cable = ReceiverAppDelegate.isCable(c, link)
            self?.showStatus(link: link)
            FileHandle.standardError.write(Data("[receiver] Handed over to \(LinkLabel.name(link))\n".utf8))
        }
        session.onPeer = { [weak self] hello in
            self?.state("Streaming from \(hello.name)", "\(hello.name)에서 스트리밍 중")
            self?.showStatus(link: link)
        }
        session.onEnd = { [weak self, weak session] reason in
            guard let self = self else { return }
            FileHandle.standardError.write(Data("[receiver] Session ended: \(reason)\n".utf8))
            if let asked = session?.askedPower, session?.powerRequest == nil {
                FileHandle.standardError.write(Data("[receiver] Ignored \(asked) request: no pairing key or cable\n".utf8))
            }
            // Only the current session's end resets the app
            guard self.session === session else { return }
            let duration = self.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let peer = session?.peer?.name ?? L10n.t("sender", "송신기")
            self.lastSummary = L10n.t("Last session: \(peer), \(duration / 60)m \(duration % 60)s — \(reason)",
                                      "마지막 연결: \(peer), \(duration / 60)분 \(duration % 60)초 — \(reason)")
            self.apply(AfterSession.action(streamed: session?.config.map { !$0.test } ?? false, relinking: session?.relinking ?? false,
                                           stoppedHere: self.stoppedHere, request: session?.powerRequest, onDisconnect: self.settings.onDisconnect))
            self.stoppedHere = false
            self.session = nil
            self.state("Waiting for a sender", "송신기를 기다리는 중")
            self.showStatus(link: nil)
        }
        self.session = session
        startedAt = Date()
        state("Connecting…", "연결하는 중…")
        session.start()
    }

    /// Display icon, with the link's mark while streaming
    /// Text on macOS 10.15, which lacks SF Symbols
    private func showStatus(link: LinkKind?) {
        if #available(macOS 11, *) {
            statusItem.button?.image = StatusIcon.image(link: link, role: .receiver)
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = link == nil ? "▭" : "▭ ●"
        }
    }

    private func hudContent() -> HUDContent? {
        guard let session = session, let config = session.config else { return nil }
        return HUDContent.make(peer: session.peer?.name, config: config, telemetry: session.telemetry)
    }

    // MARK: - Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        info("Afterscreen Receiver — \(stateLine)")
        menu.addItem(.separator())
        let display = target()
        let hardware = welcome(for: display)
        info(hardware.marketingName)
        info(L10n.t("Screen", "화면") + " \(display?.name ?? "—") · \(hardware.panelPixels.width)×\(hardware.panelPixels.height) · macOS \(hardware.osVersion)")
        info("GPU \(hardware.gpuNames.joined(separator: ", "))")
        let yes = L10n.t("yes", "지원"), no = L10n.t("no", "미지원")
        info(L10n.t("Hardware decode", "하드웨어 디코딩") + ": BC7 · HEVC \(hardware.hevcDecode ? yes : no) · Main10 \(hardware.hevcMain10Decode ? yes : no) · H.264 \(hardware.h264Decode ? yes : no)")
        info(L10n.t("Listening on port \(listener?.port ?? 0)", "포트 \(listener?.port ?? 0)에서 대기 중"))
        menu.addItem(.separator())
        info(lastSummary)
        info(L10n.t("While streaming: ⌥⌘I toggles the HUD, Esc twice stops", "스트리밍 중: ⌥⌘I로 정보 표시, Esc 두 번으로 중지"))
        menu.addItem(.separator())
        if session != nil {
            let stop = NSMenuItem(title: L10n.t("Stop Streaming", "스트리밍 중지"), action: #selector(stopStreaming), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        let prefs = NSMenuItem(title: L10n.t("Settings…", "설정…"), action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: L10n.t("Quit Afterscreen Receiver", "Afterscreen Receiver 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func stopStreaming() {
        // No session: power off a picture held for a relink
        guard let session = session else {
            screen?.end(reason: "", relink: false)
            return
        }
        stoppedHere = true
        // Power-off over the live stream; bye at black
        let stop = { session.stop(reason: L10n.t("Stopped on \(ComputerName.current)", "\(ComputerName.current)에서 연결을 끊었습니다"), pause: true) }
        guard let screen = screen else { return stop() }
        screen.powerOff(done: stop)
    }

    @objc private func showSettings() {
        openSettings(overStream: false)
    }

    /// `overStream`: opened from the stream's menu
    /// Raises the window above a screen-covering stream
    private func openSettings(overStream: Bool) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReceiverSettingsView(settings: settings, pairings: pairings)))
            window.title = L10n.t("Afterscreen Receiver Settings", "Afterscreen Receiver 설정")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // From the stream's menu: shows in its full-screen Space
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            settingsWindow = window
        }
        settingsWindow?.level = overStream ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) : .normal
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// After power-off and Space slide-back
    /// A new session by then keeps this Mac on
    private func apply(_ action: AfterSession) {
        guard action != .nothing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + StreamWindow.longestOff + 1) { [weak self] in
            guard let self = self, self.session == nil else { return }
            FileHandle.standardError.write(Data("[receiver] After the session: \(action)\n".utf8))
            // Windowed runs beside the sender: that Mac stays on
            guard !self.windowed || action == .sleepDisplay else { return }
            switch action {
            case .nothing: break
            case .sleepDisplay: ReceiverAppDelegate.pmset("displaysleepnow")
            case .sleep: ReceiverAppDelegate.pmset("sleepnow")
            case .shutDown:
                guard !Shutdown.now() else { return }
                FileHandle.standardError.write(Data("[receiver] Shut down not allowed: sleeping instead\n".utf8))
                ReceiverAppDelegate.pmset("sleepnow")
            }
        }
    }

    /// Needs no privileges
    private static func pmset(_ command: String) {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = [command]
        try? pmset.run()
    }

    /// This app's visible windows over transparency, shadows included
    /// Own windows only: no Screen Recording prompt
    private static func saveScreen() {
        // Window IDs as raw values, as the call takes them
        var ids = NSApp.windows.filter(\.isVisible).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        guard !ids.isEmpty, let list = CFArrayCreate(nil, &ids, ids.count, nil),
              let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: list, imageOption: .bestResolution),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "/tmp/afterscreen-screen.png"))
    }
}
