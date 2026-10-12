import Foundation
import AfterscreenCore

/// Max full-motion resolution and fps of link and receiver
/// Then the fps of typical use at the session's size
public enum QualityTest {
    public struct Stage: Equatable {
        public var size: PixelSize
        public var fps: Double
        public var gbps: Double
        /// Video layer carrying motion; nil on the tile path
        public var motion: PixelSize? = nil
        /// Video bitrate the stage ended at; shared links lower it
        public var videoBitrate: Int? = nil
    }

    /// Progress and results, published through the session snapshot
    public struct Report: Equatable {
        public var receiver: String
        public var link: LinkKind?
        public var path = ""
        /// Full-motion stages, smallest first
        public var stages: [Stage] = []
        /// Video window and scrolling text only, at the session's size
        public var typical: Stage?
        /// Size being measured; nil once finished
        public var running: PixelSize?
        public var runningTypical = false
        public var total = 0
        /// Receiver's refresh: the rate stages aim for
        public var frameRate = 60.0

        public var verdict: Stage? { QualityTest.verdict(stages, frameRate: frameRate) }
        public var done: Int { stages.count + (typical == nil ? 0 : 1) }
    }

    /// Panel fractions measured: 5K gives 1080p, 1440p, 4K, 5K
    static let scales = [0.375, 0.5, 0.75, 1.0]
    /// Measured part of each stage
    static let measureSeconds = 2.0
    /// Longest wait for the receiver's window to show
    static let showWait = 5.0
    /// Smooth: 55 of 60 frames, at any refresh
    static let smoothShare = 55.0 / 60

    public static func smoothFPS(_ frameRate: Double) -> Double { frameRate * smoothShare }

    /// Skipped at stage start; at most 5 s
    /// Receiver fps counter spans one second
    /// New stream opens with lossless frames, one byte per pixel
    /// Slow links take a while to carry them
    static func warmup(stage: PixelSize, capacityGbps: Double?) -> Double {
        min(5, 1 + 2 * Double(stage.pixelCount) * 8 / ((capacityGbps ?? 0) * 1e9))
    }

    public static func stages(panel: PixelSize) -> [PixelSize] {
        scales.map { PathPolicy.aligned(PixelSize(width: Int(Double(panel.width) * $0), height: Int(Double(panel.height) * $0))) }
    }

    public static func label(_ s: PixelSize) -> String {
        s.width >= 5000 ? "5K" : (s.width >= 3800 ? "4K" : "\(s.height)p")
    }

    /// On the pattern; English, like a test card
    /// Link first: photos of the screen name it
    public static func caption(_ size: PixelSize, link: LinkKind, step: Int, of count: Int, typical: Bool) -> String {
        let stage = typical ? "Typical use · \(size.width)×\(size.height) · \(step)/\(count)" : "\(label(size)) · \(step)/\(count) · Full motion"
        return "\(linkName(link)) · \(stage)"
    }

    /// LinkLabel's names, never localised
    static func linkName(_ link: LinkKind) -> String {
        switch link {
        case .thunderbolt: return "Thunderbolt"
        case .usb: return "USB"
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .loopback: return "Loopback"
        case .unsupported: return "Unsupported link"
        }
    }

    /// Largest stage at a smooth frame rate
    public static func verdict(_ stages: [Stage], frameRate: Double) -> Stage? {
        stages.filter { $0.fps >= smoothFPS(frameRate) }.max { $0.size.pixelCount < $1.size.pixelCount }
    }
}

/// Streams the test pattern through the real pipeline
/// One stage per size, then typical use; main queue
final class QualityTestRun {
    typealias Step = (config: StreamConfig, motion: TestPattern.Motion)

    var onReport: ((QualityTest.Report) -> Void)?
    var onFinish: (() -> Void)?

    private let connection: Connection
    private let plan: [Step]
    private let capacityGbps: Double?
    private let pattern: TestPattern
    private var report: QualityTest.Report
    private var index = -1
    private var streamer: FrameStreamer?
    /// Pattern frames at the stream's rate
    private var ticker: DispatchSourceTimer?
    private var stageStart = 0.0
    private var warmup = 1.0
    private var samples: [Double] = []
    /// Receiver picture on screen at its last report
    /// Its window opens during the first stage
    private var shown = false
    /// Stage clock running: warm-up, then measured seconds
    private var timing = false
    private var stopped = false
    private let queue = DispatchQueue(label: "afterscreen.test", qos: .userInteractive, autoreleaseFrequency: .workItem)

    init?(connection: Connection, configs: [StreamConfig], typical: StreamConfig?, capacityGbps: Double?, report: QualityTest.Report) {
        guard let pattern = TestPattern(), !configs.isEmpty else { return nil }
        self.connection = connection
        plan = configs.map { ($0, .full) } + (typical.map { [($0, .typical)] } ?? [])
        self.capacityGbps = capacityGbps
        self.pattern = pattern
        self.report = report
        self.report.total = plan.count
    }

    func start() { next() }

    func requestKeyframe() {
        streamer?.requestKeyframe()
    }

    func stop() {
        stopped = true
        ticker?.cancel()
        ticker = nil
        streamer?.stop()
        streamer = nil
    }

    /// Displayed fps after the warm-up counts toward the stage
    /// Older receivers report nothing: taken as shown
    func receiverStats(_ stats: ReceiverStats) {
        shown = stats.shown ?? true
        guard timing else {
            // Half a stats interval later: samples avoid warm-up boundary
            if shown { startClock(after: 0.5) }
            return
        }
        if shown, ProcessInfo.processInfo.systemUptime - stageStart >= warmup { samples.append(stats.displayedFPS) }
    }

    private func next() {
        guard !stopped else { return }
        ticker?.cancel()
        ticker = nil
        if let streamer = streamer, index >= 0 {
            let bytes = streamer.takeCounters().bytes
            let fps = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            let step = plan[index]
            let stage = QualityTest.Stage(size: step.config.streamPixels, fps: fps,
                                          gbps: Double(bytes) * 8 / QualityTest.measureSeconds / 1e9, motion: step.config.video?.pixels,
                                          videoBitrate: streamer.videoBitrates?.now)
            if step.motion == .typical { report.typical = stage } else { report.stages.append(stage) }
        }
        index += 1
        let old = streamer
        streamer = nil
        guard index < plan.count else {
            old?.stop()
            report.running = nil
            report.runningTypical = false
            onReport?(report)
            onFinish?()
            return
        }
        // Next config only after the previous stage's last frame
        guard let previous = old else { return begin(plan[index]) }
        previous.stop { [weak self] in DispatchQueue.main.async { self.map { $0.begin($0.plan[$0.index]) } } }
    }

    private func begin(_ step: Step) {
        let config = step.config
        guard !stopped, let streamer = try? FrameStreamer(config: config, capacityGbps: capacityGbps, connection: connection) else { return next() }
        connection.send(.config, json: config)
        self.streamer = streamer
        samples = []
        timing = false
        report.running = config.streamPixels
        report.runningTypical = step.motion == .typical
        onReport?(report)

        let size = config.streamPixels, fps = config.frameRate, start = ProcessInfo.processInfo.systemUptime, pattern = self.pattern
        let caption = QualityTest.caption(size, link: config.linkKind, step: index + 1, of: plan.count, typical: step.motion == .typical)
        let stage = TestPattern.Stage(caption: caption,
                                      frameRate: config.frameRate, motion: step.motion)
        // Index from the clock: a stalled tick skips, never repeats
        // Up to 3/4 of a period late still counts as on time
        var last = -1
        ticker = DispatchSource.repeating(on: queue, every: 1 / fps, leeway: .milliseconds(1)) {
            let frame = max(last + 1, Int(((ProcessInfo.processInfo.systemUptime - start) * fps + 0.25).rounded(.down)))
            last = frame
            if let picture = pattern.frame(size: size, index: frame, stage: stage) {
                streamer.offer(CapturedFrame(pixelBuffer: picture, dirty: pattern.changing(size: size, stage: stage)))
            }
        }
        if shown { return startClock() }
        // Hidden window draws nothing: clock starts once it shows
        DispatchQueue.main.asyncAfter(deadline: .now() + QualityTest.showWait) { [weak self, weak streamer] in
            guard let self = self, self.streamer === streamer, !self.timing else { return }
            self.startClock()
        }
    }

    /// Warm-up from `delay` on, then the measured seconds
    private func startClock(after delay: Double = 0) {
        guard let streamer = streamer else { return }
        timing = true
        stageStart = ProcessInfo.processInfo.systemUptime + delay
        warmup = QualityTest.warmup(stage: plan[index].config.streamPixels, capacityGbps: capacityGbps)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + warmup) { [weak self, weak streamer] in
            guard self?.streamer === streamer else { return }
            _ = streamer?.takeCounters()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + warmup + QualityTest.measureSeconds) { [weak self, weak streamer] in
            guard let self = self, self.streamer === streamer else { return }
            self.next()
        }
    }
}
