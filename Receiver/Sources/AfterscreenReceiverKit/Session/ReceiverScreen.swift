import AppKit
import IOKit.pwr_mgt
import Metal
import AfterscreenCore

/// StreamDisplay backed by the fullscreen window and Metal renderer
public final class ReceiverScreen: StreamDisplay {
    public var onExitRequest: (() -> Void)?
    /// Main queue: a sender switching links did not come back
    public var onRelinkTimeout: (() -> Void)?
    /// Main queue: Settings… from the stream's right-click menu
    public var onSettingsRequest: (() -> Void)?
    var hudContent: (() -> HUDContent?)? {
        didSet { window.hudContent = hudContent }
    }
    /// Main queue: HUD corner and fold; changes go to `onHUDChange`
    var hudPlacement: (corner: ReceiverSettings.HUDCorner, collapsed: Bool) {
        get { (window.hudCorner, window.hudCollapsed) }
        set {
            window.hudCorner = newValue.corner
            window.hudCollapsed = newValue.collapsed
        }
    }
    var onHUDChange: ((ReceiverSettings.HUDCorner, Bool) -> Void)? {
        didSet { window.onHUDChange = onHUDChange }
    }

    // Per-item autorelease: busy queue would retain payloads via Metal objects
    public let decodeQueue = DispatchQueue(label: "afterscreen.decode", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let renderer: StreamRenderer
    private var snapshotSignal: DispatchSourceSignal?
    private let window: StreamWindow
    private let audio = AudioPlayer()
    private let output = OutputMirror()
    /// Held while a stream shows; input arrives on the sender
    /// Without it the iMac idles into display sleep
    private var awake: NSObjectProtocol?
    /// Declared user activity; held until the stream ends
    private var userActivity = IOPMAssertionID(0)

    /// `display`: the screen sessions show on
    public init?(windowed: Bool = false, display: CGDirectDisplayID = CGMainDisplayID()) {
        guard let device = GPUChoice.device(for: display, streaming: false), let renderer = StreamRenderer(device: device) else { return nil }
        self.renderer = renderer
        // `kill -USR1 <pid>` saves the next drawn frame
        // For SSH debugging: screen captures there miss the stream
        signal(SIGUSR1, SIG_IGN)
        let snapshot = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        snapshot.setEventHandler { [weak renderer] in renderer?.requestSnapshot() }
        snapshot.resume()
        snapshotSignal = snapshot
        window = StreamWindow(renderer: renderer, windowed: windowed)
        window.onExitRequest = { [weak self] in self?.onExitRequest?() }
        window.onSettingsRequest = { [weak self] in self?.onSettingsRequest?() }
        window.onWaveRedraw = { [weak self] in self?.onRedrawNeeded?() }
        window.onVisibilityChange = { [weak self] visible in
            self?.renderer.setVisible(visible)
            if visible { self?.onRedrawNeeded?() }
        }
        window.onShownChange = { [weak self] in self?.isShown = $0 }
        self.display = display
    }

    public var gpuName: String { renderer.deviceName }

    public var gpuMeter: GPUTimeMeter { renderer.gpuMeter }
    public var displayedFPS: Double { renderer.displayed.ratePerSecond() }
    /// Set on main by the window, read by stats
    public private(set) var isShown: Bool {
        get { shownLock.lock(); defer { shownLock.unlock() }; return shown }
        set {
            shownLock.lock()
            shown = newValue
            shownLock.unlock()
        }
    }
    private let shownLock = NSLock()
    private var shown = false
    public var lateFrames: Int { renderer.lateFrames }
    public var uploadMs: Double { renderer.uploadMs }
    public var decodeMs: Double { renderer.decodeMs }

    public func begin(config: StreamConfig) {
        settle?.cancel()
        settle = nil
        window.show(config: config)
        if awake == nil {
            // Wakes a display slept by the last session's end
            // The activity below only keeps it awake
            IOPMAssertionDeclareUserActivity("Afterscreen stream" as CFString, kIOPMUserActiveLocal, &userActivity)
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Showing a Afterscreen stream")
        }
    }

    /// Main queue: the screen for the next session
    /// Read on the session's queue for brightness
    public var display: CGDirectDisplayID {
        get { displayLock.lock(); defer { displayLock.unlock() }; return chosenDisplay }
        set {
            displayLock.lock()
            chosenDisplay = newValue
            displayLock.unlock()
            window.display = newValue
        }
    }
    private let displayLock = NSLock()
    private var chosenDisplay = CGMainDisplayID()

    /// Main queue: applies from the next session
    public var matchPanelMode: Bool {
        get { window.matchPanelMode }
        set { window.matchPanelMode = newValue }
    }

    /// Main queue: applies from the next session
    public var presentation: ReceiverSettings.Presentation {
        get { window.presentation }
        set { window.presentation = newValue }
    }

    /// Main queue: applies from the next session
    /// Read on the decode queue as a session ends
    public var effect: ReceiverSettings.Effect {
        get { effectLock.lock(); defer { effectLock.unlock() }; return chosenEffect }
        set {
            effectLock.lock()
            chosenEffect = newValue
            effectLock.unlock()
            window.effect = newValue
        }
    }
    private let effectLock = NSLock()
    private var chosenEffect = ReceiverSettings.Effect.tiles

    public var onRedrawNeeded: (() -> Void)?

    public func redraw() {
        renderer.redraw()
    }

    public func prepare(config: StreamConfig) {
        renderer.dropFarewell()
        renderer.reset()
        streaming = true
        let id = display
        // Requested first: the panel moves while pipelines build
        if GPUChoice.kind(for: id, streaming: true) == .discrete { discrete.hold() }
        // Not drawing on it: the panel stays put
        if !use(GPUChoice.device(for: id, streaming: true)) { discrete.release() }
    }

    public func releaseDecodeResources() {
        // Tile wave closes over the last picture, after texture release
        if effect == .tiles { renderer.keepFarewell() }
        renderer.releaseResources()
        streaming = false
    }

    /// Decode queue: between `prepare` and `releaseDecodeResources`
    private var streaming = false
    /// Decode queue
    private let discrete = DiscreteGPURequest()
    /// Main queue: return to the idle GPU, cancelled by `begin`
    private var settle: DispatchWorkItem?

    /// Decode queue: false when not drawing on `device`
    @discardableResult
    private func use(_ device: MTLDevice?) -> Bool {
        guard let device = device else { return false }
        guard device.registryID != renderer.deviceID else { return true }
        let moved = renderer.use(device)
        let line = moved ? "Drawing on \(device.name)" : "Still on \(renderer.deviceName): \(device.name) failed"
        FileHandle.standardError.write(Data("[receiver] \(line); screen on \(GPUChoice.drivingName(display))\n".utf8))
        return moved
    }

    /// Main queue: the idle GPU once the window has closed
    /// After the Space's slide: a GPU switch mid-slide stutters
    /// The discrete request goes after the renderer leaves it
    private func settleGPU() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.decodeQueue.async {
                guard let self = self, !self.streaming else { return }
                self.use(GPUChoice.device(for: self.display, streaming: false))
                self.discrete.release()
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + StreamWindow.longestOff + 1.5, execute: work)
    }

    public func end(reason: String, relink: Bool) {
        audio.stop()
        // Link or size change: the next session takes this window
        // Power effects skipped; output level kept for the sender's return
        // Already powered off: closed like any end
        if relink, window.isPoweredOn {
            return window.hold(for: StreamWindow.relinkWait) { [weak self] in
                self?.releaseAwake()
                self?.output.restore()
                self?.settleGPU()
                self?.onRelinkTimeout?()
            }
        }
        window.hide()
        releaseAwake()
        output.restore()
        settleGPU()
    }

    /// Main queue: puts back the iMac's own output level
    /// Sound stops first: no tail at the iMac's own level
    public func restoreOutput() {
        audio.stop()
        output.restore()
    }

    public func powerOff(done: @escaping () -> Void) {
        window.powerOff(done: done)
    }

    private func releaseAwake() {
        if let a = awake { ProcessInfo.processInfo.endActivity(a) }
        awake = nil
        if userActivity != 0 { IOPMAssertionRelease(userActivity) }
        userActivity = 0
    }

    public func showTiles(_ frame: TileFrame, present: Bool) -> Bool {
        renderer.applyTiles(frame, present: present)
    }

    public func setVideoParams(codec: VideoCodec, tenBit: Bool, parameterSets: [Data]) -> Bool {
        renderer.setVideoParams(codec: codec, tenBit: tenBit, parameterSets: parameterSets)
    }

    public func decodeVideo(avcc: Data) -> Bool {
        renderer.decodeVideo(avcc: avcc)
    }

    public func cursor(x: Float, y: Float, visible: Bool) {
        window.setCursor(x: x, y: y, visible: visible)
    }

    public func cursorImage(_ image: CursorImage) {
        window.setCursorImage(image)
    }

    public func playAudio(_ packet: AudioWire.Packet) {
        audio.play(packet)
    }

    public var audioBuffered: Double? { audio.bufferedSeconds }

    public var audioUnderruns: Int { audio.underruns }

    public func followOutput(_ level: OutputLevel?) {
        guard level != nil else { return restoreOutput() }
        output.follow(level)
    }

    public func setDeband(_ level: Deband) {
        renderer.setDeband(level)
    }

    public func showCongestionNotice(wifi: Bool) {
        window.showNotice(L10n.t("The network is busy, so picture quality was lowered", "네트워크가 혼잡해 화질을 낮췄습니다"),
                          detail: wifi ? L10n.t("A cable connection is steadier", "케이블로 연결하면 더 안정적입니다") : nil)
    }

    public func setBrightness(_ light: PanelLight) {
        let id = display
        guard let nits = light.nits, let peak = panelPeakNits else { return PanelBrightness.set(light.level, display: id) }
        PanelBrightness.set(nits: nits, peak: peak, display: id)
    }

    public var panelLevel: Double? { PanelBrightness.level(display) }

    /// This panel's peak in nits
    /// Built-in XDR: its rating; others measured once, kept per panel
    /// Too dim to measure yet: the sender's slider stands in
    public var panelPeakNits: Double? {
        let id = display
        if CGDisplayIsBuiltin(id) != 0, let rated = PanelBrightness.ratedBuiltInNits { return rated }
        let key = "panelPeakNits.\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        if let kept = UserDefaults.standard.object(forKey: key) as? Double { return kept }
        guard let measured = PanelBrightness.measuredPeakNits(id) else { return nil }
        UserDefaults.standard.set(measured, forKey: key)
        return measured
    }
}
