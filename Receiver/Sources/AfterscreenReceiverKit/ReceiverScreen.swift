import AppKit
import IOKit.pwr_mgt
import Metal
import AfterscreenCore

/// StreamDisplay backed by the fullscreen window and Metal renderer
public final class ReceiverScreen: StreamDisplay {
    public var onExitRequest: (() -> Void)?
    /// Main queue: Settings… from the stream's right-click menu
    public var onSettingsRequest: (() -> Void)?
    var hudContent: (() -> HUDContent?)? {
        didSet { window.hudContent = hudContent }
    }
    /// Main queue: HUD corner and fold, reported back on change for the settings
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

    private let renderer: StreamRenderer
    private var snapshotSignal: DispatchSourceSignal?
    private let window: StreamWindow
    private let audio = AudioPlayer()
    /// Held while a stream is shown: input arrives on the sender, so the iMac would idle into display sleep
    private var awake: NSObjectProtocol?

    public init?(windowed: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = StreamRenderer(device: device) else { return nil }
        self.renderer = renderer
        // `kill -USR1 <pid>` saves the next drawn frame: debugging over SSH, where screen captures miss the stream
        signal(SIGUSR1, SIG_IGN)
        let snapshot = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        snapshot.setEventHandler { [weak renderer] in renderer?.requestSnapshot() }
        snapshot.resume()
        snapshotSignal = snapshot
        window = StreamWindow(renderer: renderer, windowed: windowed)
        window.onExitRequest = { [weak self] in self?.onExitRequest?() }
        window.onSettingsRequest = { [weak self] in self?.onSettingsRequest?() }
        window.onVisibilityChange = { [weak self] visible in
            self?.renderer.setVisible(visible)
            if visible { self?.onRedrawNeeded?() }
        }
    }

    public var gpuMeter: GPUTimeMeter { renderer.gpuMeter }
    public var displayedFPS: Double { renderer.displayed.ratePerSecond() }
    public var lateFrames: Int { renderer.lateFrames }
    public var uploadMs: Double { renderer.uploadMs }
    public var decodeMs: Double { renderer.decodeMs }

    public func begin(config: StreamConfig) {
        window.show(config: config)
        if awake == nil {
            // Wakes a display the last session's end put to sleep; the activity below only keeps it awake
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Afterscreen stream" as CFString, kIOPMUserActiveLocal, &id)
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Showing a Afterscreen stream")
        }
    }

    /// Main queue: applies from the next session
    public var presentation: ReceiverSettings.Presentation {
        get { window.presentation }
        set { window.presentation = newValue }
    }

    public var onRedrawNeeded: (() -> Void)?

    public func redraw() {
        renderer.redraw()
    }

    public func prepare(config: StreamConfig) {
        renderer.reset()
    }

    public func releaseDecodeResources() {
        renderer.releaseResources()
    }

    public func end(reason: String) {
        window.hide()
        audio.stop()
        if let a = awake { ProcessInfo.processInfo.endActivity(a) }
        awake = nil
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

    public var brightness: Double? { Brightness.level }

    public func playAudio(_ packet: AudioWire.Packet) {
        audio.play(packet)
    }

    public var audioBuffered: Double? { audio.bufferedSeconds }

    public var audioUnderruns: Int { audio.underruns }

    public var volume: Double { audio.volume }

    public func setVolume(_ level: Double) {
        audio.volume = level
    }

    public func setDeband(_ level: Deband) {
        renderer.setDeband(level)
    }

    public func setBrightness(_ level: Double) {
        Brightness.set(level)
    }
}
