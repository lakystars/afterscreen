import AppKit
import Metal
import AfterscreenCore

/// StreamDisplay backed by the fullscreen window and Metal renderer
public final class ReceiverScreen: StreamDisplay {
    public var onExitRequest: (() -> Void)?
    public var hudText: (() -> String)? {
        didSet { window.hudText = hudText }
    }

    private let renderer: StreamRenderer
    private let window: StreamWindow
    /// Held while a stream is shown: input arrives on the sender, so the iMac would idle into display sleep
    private var awake: NSObjectProtocol?

    public init?(windowed: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = StreamRenderer(device: device) else { return nil }
        self.renderer = renderer
        window = StreamWindow(renderer: renderer, windowed: windowed)
        window.onExitRequest = { [weak self] in self?.onExitRequest?() }
    }

    public var gpuMeter: GPUTimeMeter { renderer.gpuMeter }
    public var displayedFPS: Double { renderer.displayed.ratePerSecond() }
    public var lateFrames: Int { renderer.lateFrames }
    public var uploadMs: Double { renderer.uploadMs }
    public var decodeMs: Double { renderer.decodeMs }

    public func begin(config: StreamConfig) {
        window.show(config: config)
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Showing a Afterscreen stream")
        }
    }

    public func prepare(config: StreamConfig) {
        renderer.reset()
    }

    public func releaseDecodeResources() {
        renderer.releaseResources()
    }

    public func end(reason: String) {
        window.hide()
        if let a = awake { ProcessInfo.processInfo.endActivity(a) }
        awake = nil
    }

    public func showTiles(_ frame: TileFrame) -> Bool {
        renderer.applyTiles(frame)
    }

    public func setVideoParams(codec: VideoCodec, parameterSets: [Data]) -> Bool {
        renderer.setVideoParams(codec: codec, parameterSets: parameterSets)
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
}
