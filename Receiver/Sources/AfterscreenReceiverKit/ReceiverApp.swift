import AppKit
import AfterscreenCore
import SwiftUI

/// Menu bar app: advertises over Bonjour, accepts one sender at a time
public final class ReceiverAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NetServiceDelegate {
    private var statusItem: NSStatusItem!
    private var listener: Listener?
    private var service: NetService?
    private var session: ReceiverSession?
    private var screen: ReceiverScreen?
    private var hardware: Welcome!
    /// First: it sets the UI language the other properties' text uses
    private let settings = ReceiverSettings()
    private var lastSummary = L10n.t("No session yet", "아직 연결한 적 없음")
    private var stateLine = L10n.t("Starting…", "시작하는 중…")

    /// Shown in the user's language, logged in English for scripts that wait on it
    private func state(_ english: String, _ korean: String) {
        stateLine = L10n.t(english, korean)
        FileHandle.standardError.write(Data("[receiver] \(english)\n".utf8))
    }
    private var startedAt: Date?
    private var settingsWindow: NSWindow?
    /// The session was stopped on this Mac, so its display stays on
    private var stoppedHere = false

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let name = Host.current().localizedName ?? "iMac"
        hardware = HardwareInfo.welcome(name: name)
        // Development: report another panel, e.g. --panel 5120x2880
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--panel"), i + 1 < args.count {
            let wh = args[i + 1].split(separator: "x").compactMap { Int($0) }
            if wh.count == 2 {
                hardware.panelPixels = PixelSize(width: wh[0], height: wh[1])
                hardware.panelPoints = HardwareInfo.points(forPanel: hardware.panelPixels)
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▭"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        screen = ReceiverScreen(windowed: CommandLine.arguments.contains("--windowed"))
        screen?.onExitRequest = { [weak self] in self?.stopStreaming() }
        screen?.hudText = { [weak self] in self?.hudText() ?? "" }
        guard screen != nil else {
            state("Metal is unavailable on this Mac", "이 Mac에서는 Metal을 쓸 수 없습니다")
            return
        }
        do {
            let listener = try Listener()
            listener.onAccept = { [weak self] c in DispatchQueue.main.async { self?.accept(c) } }
            listener.start()
            self.listener = listener
            publish(port: listener.port, name: name)
            state("Waiting for a sender", "송신기를 기다리는 중")
        } catch {
            state("Cannot listen: \(error)", "연결을 받을 수 없습니다: \(error)")
        }
    }

    private func publish(port: UInt16, name: String) {
        let service = NetService(domain: "local.", type: AfterscreenProtocol.bonjourType + ".", name: name, port: Int32(port))
        let txt: [String: Data] = [
            "model": Data(hardware.marketingName.utf8),
            "panel": Data("\(hardware.panelPixels.width)x\(hardware.panelPixels.height)".utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        self.service = service
    }

    private func refuse(_ connection: Connection, _ reason: String) {
        connection.send((try? JSONWire.message(.bye, Bye(reason: reason))) ?? Message(type: .bye))
        connection.closeAfterFlush(reason: reason)
    }

    private func accept(_ connection: Connection) {
        if let session = session { return session.offerChannel(connection) }
        guard let screen = screen else { return refuse(connection, L10n.t("Receiver display is unavailable", "수신기 화면을 쓸 수 없습니다")) }
        let link = connection.localInterfaceName.map { LinkClassifier.classify(LinkClassifier.facts(for: $0)) } ?? .unsupported
        guard settings.accepts(link) else { return refuse(connection, L10n.t("This receiver accepts Thunderbolt, USB and Ethernet only",
                                                                              "이 수신기는 Thunderbolt, USB, 이더넷 연결만 받습니다")) }
        let session = ReceiverSession(connection: connection, hardware: hardware, display: screen)
        session.onPeer = { [weak self] hello in
            self?.state("Streaming from \(hello.name)", "\(hello.name)에서 스트리밍 중")
            self?.statusItem.button?.title = "▭ ●"
        }
        session.onEnd = { [weak self] reason in
            guard let self = self else { return }
            let duration = self.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let peer = self.session?.peer?.name ?? L10n.t("sender", "송신기")
            self.lastSummary = L10n.t("Last session: \(peer), \(duration / 60)m \(duration % 60)s — \(reason)",
                                      "마지막 연결: \(peer), \(duration / 60)분 \(duration % 60)초 — \(reason)")
            // Only after a session that showed a stream: early failures would put the display to sleep on every retry
            if let config = self.session?.config, !config.test, self.settings.onDisconnect == .sleepDisplay && !self.stoppedHere {
                ReceiverAppDelegate.sleepDisplay()
            }
            self.stoppedHere = false
            self.session = nil
            FileHandle.standardError.write(Data("[receiver] Session ended: \(reason)\n".utf8))
            self.state("Waiting for a sender", "송신기를 기다리는 중")
            self.statusItem.button?.title = "▭"
        }
        self.session = session
        startedAt = Date()
        state("Connecting…", "연결하는 중…")
        session.start()
    }

    private func hudText() -> String {
        guard let session = session, let config = session.config, let screen = screen else { return "" }
        let link: String
        switch config.linkKind {
        case .thunderbolt: link = "ϟ Thunderbolt"
        case .usb: link = "⌁ USB"
        case .ethernet: link = L10n.t("⇄ Ethernet", "⇄ 이더넷")
        case .wifi: link = "≋ Wi-Fi"
        case .loopback: link = L10n.t("Loopback", "루프백")
        case .unsupported: link = L10n.t("Unsupported", "지원 안 함")
        }
        let path = config.video.map { v in
            L10n.t("tiles + \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10-bit" : "") \(v.pixels.width)×\(v.pixels.height)",
                   "타일 + \(v.codec.rawValue.uppercased())\(v.tenBit ? " 10비트" : "") \(v.pixels.width)×\(v.pixels.height)")
        } ?? L10n.t("tiles (BC7)", "타일(BC7)")
        let title = config.test ? L10n.t("Afterscreen quality test", "Afterscreen 품질 테스트") : "Afterscreen"
        return """
         \(title)  \(link)
         \(config.streamPixels.width)×\(config.streamPixels.height) \(path)
         \(L10n.t("shown", "표시")) \(String(format: "%.0f", screen.displayedFPS)) fps · \(L10n.t("late", "지연")) \(screen.lateFrames)
         upload \(Format.ms(screen.uploadMs)) · GPU \(Format.percent(screen.gpuMeter.lastPercent))
         \(L10n.t("⌥⌘I hide · Esc Esc stop", "⌥⌘I 숨김 · Esc 두 번 중지"))
        """
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
        info(hardware.marketingName)
        info(L10n.t("Panel", "패널") + " \(hardware.panelPixels.width)×\(hardware.panelPixels.height) · macOS \(hardware.osVersion)")
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
        stoppedHere = true
        session?.stop(reason: L10n.t("Stopped on the iMac", "iMac에서 연결을 끊었습니다"), pause: true)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReceiverSettingsView(settings: settings)))
            window.title = L10n.t("Afterscreen Receiver Settings", "Afterscreen Receiver 설정")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Same as `pmset displaysleepnow`, which needs no privileges
    private static func sleepDisplay() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        try? pmset.run()
    }
}
