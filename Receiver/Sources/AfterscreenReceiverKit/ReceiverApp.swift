import AppKit
import AfterscreenCore

/// Menu bar app: advertises over Bonjour, accepts one sender at a time
public final class ReceiverAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NetServiceDelegate {
    private var statusItem: NSStatusItem!
    private var listener: Listener?
    private var service: NetService?
    private var session: ReceiverSession?
    private var screen: ReceiverScreen?
    private var hardware: Welcome!
    private var lastSummary = "No session yet"
    private var stateLine = "Starting…" {
        didSet { FileHandle.standardError.write(Data("[receiver] \(stateLine)\n".utf8)) }
    }
    private var startedAt: Date?

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
        screen?.onExitRequest = { [weak self] in self?.session?.stop(reason: "Stopped on the receiver") }
        screen?.hudText = { [weak self] in self?.hudText() ?? "" }
        guard screen != nil else {
            stateLine = "Metal is unavailable on this Mac"
            return
        }
        do {
            let listener = try Listener()
            listener.onAccept = { [weak self] c in DispatchQueue.main.async { self?.accept(c) } }
            listener.start()
            self.listener = listener
            publish(port: listener.port, name: name)
            stateLine = "Waiting for a sender"
        } catch {
            stateLine = "Cannot listen: \(error)"
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

    private func accept(_ connection: Connection) {
        guard session == nil, let screen = screen else {
            connection.send((try? JSONWire.message(.bye, Bye(reason: "Receiver is busy with another sender"))) ?? Message(type: .bye))
            connection.closeAfterFlush(reason: "busy")
            return
        }
        let session = ReceiverSession(connection: connection, hardware: hardware, display: screen)
        session.onPeer = { [weak self] hello in
            self?.stateLine = "Streaming from \(hello.name)"
            self?.statusItem.button?.title = "▭ ●"
        }
        session.onEnd = { [weak self] reason in
            guard let self = self else { return }
            let duration = self.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            self.lastSummary = "Last session: \(self.session?.peer?.name ?? "sender"), \(duration / 60)m \(duration % 60)s — \(reason)"
            self.session = nil
            self.stateLine = "Waiting for a sender"
            self.statusItem.button?.title = "▭"
        }
        self.session = session
        startedAt = Date()
        stateLine = "Connecting…"
        session.start()
    }

    private func hudText() -> String {
        guard let session = session, let config = session.config, let screen = screen else { return "" }
        let link: String
        switch config.linkKind {
        case .thunderbolt: link = "ϟ Thunderbolt"
        case .usb: link = "⌁ USB"
        case .wifi: link = "Wi-Fi"
        case .loopback: link = "Loopback"
        case .unsupported: link = "Unsupported"
        }
        let path = config.path == .tile ? "tiles (BC7)" : "video (\(config.codec?.rawValue.uppercased() ?? "?"))"
        return """
         Afterscreen  \(link)
         \(config.streamPixels.width)×\(config.streamPixels.height) \(path)
         displayed \(String(format: "%.0f", screen.displayedFPS)) fps · late \(screen.lateFrames)
         upload \(Format.ms(screen.uploadMs)) · GPU \(Format.percent(screen.gpuMeter.lastPercent))
         ⌥⌘I hide · Esc Esc stop
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
        info("Panel \(hardware.panelPixels.width)×\(hardware.panelPixels.height) · macOS \(hardware.osVersion)")
        info("GPU \(hardware.gpuNames.joined(separator: ", "))")
        info("Decode: BC7 tiles · HEVC \(hardware.hevcDecode ? "yes" : "no") · H.264 \(hardware.h264Decode ? "yes" : "no")")
        info("Listening on port \(listener?.port ?? 0)")
        menu.addItem(.separator())
        info(lastSummary)
        info("While streaming: ⌥⌘I toggles the HUD, Esc twice stops")
        menu.addItem(.separator())
        if session != nil {
            let stop = NSMenuItem(title: "Stop Streaming", action: #selector(stopStreaming), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(NSMenuItem(title: "Quit Afterscreen Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func stopStreaming() {
        session?.stop(reason: "Stopped on the receiver")
    }
}
