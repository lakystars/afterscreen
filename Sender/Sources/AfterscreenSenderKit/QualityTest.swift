import Foundation
import AfterscreenCore

/// Highest resolution and frame rate the link and receiver sustain under full motion
public enum QualityTest {
    public struct Stage: Equatable {
        public var size: PixelSize
        public var fps: Double
        public var gbps: Double
    }

    /// Progress and results, published through the session snapshot
    public struct Report: Equatable {
        public var receiver: String
        public var link: LinkKind?
        public var path = ""
        public var stages: [Stage] = []
        /// Size being measured; nil once finished
        public var running: PixelSize?
        public var total = 0

        public var verdict: Stage? { QualityTest.verdict(stages) }
    }

    /// Panel fractions measured: 5K gives 1080p, 1440p, 4K, 5K
    static let scales = [0.375, 0.5, 0.75, 1.0]
    static let stageSeconds = 3.0
    /// Left out of each stage: the receiver's fps counter spans one second
    static let warmup = 1.0
    public static let smoothFPS = 55.0

    public static func stages(panel: PixelSize) -> [PixelSize] {
        scales.map { PathPolicy.aligned(PixelSize(width: Int(Double(panel.width) * $0), height: Int(Double(panel.height) * $0))) }
    }

    public static func label(_ s: PixelSize) -> String {
        s.width >= 5000 ? "5K" : (s.width >= 3800 ? "4K" : "\(s.height)p")
    }

    /// Largest stage at a smooth frame rate
    public static func verdict(_ stages: [Stage]) -> Stage? {
        stages.filter { $0.fps >= smoothFPS }.max { $0.size.pixelCount < $1.size.pixelCount }
    }
}

/// Streams the test pattern through the real pipeline, one stage per size. Main queue
final class QualityTestRun {
    var onReport: ((QualityTest.Report) -> Void)?
    var onFinish: (() -> Void)?

    private let connection: Connection
    private let configs: [StreamConfig]
    private let capacityGbps: Double?
    private let pattern: TestPattern
    private var report: QualityTest.Report
    private var index = -1
    private var streamer: FrameStreamer?
    /// 60 Hz pattern frames for the current stage
    private var ticker: DispatchSourceTimer?
    private var stageStart = 0.0
    private var samples: [Double] = []
    private var stopped = false
    private let queue = DispatchQueue(label: "afterscreen.test", qos: .userInteractive, autoreleaseFrequency: .workItem)

    init?(connection: Connection, configs: [StreamConfig], capacityGbps: Double?, report: QualityTest.Report) {
        guard let pattern = TestPattern(), !configs.isEmpty else { return nil }
        self.connection = connection
        self.configs = configs
        self.capacityGbps = capacityGbps
        self.pattern = pattern
        self.report = report
        self.report.total = configs.count
    }

    func start() { next() }

    func stop() {
        stopped = true
        ticker?.cancel()
        ticker = nil
        streamer?.stop()
        streamer = nil
    }

    /// Displayed fps after the warm-up counts toward the stage
    func receiverStats(_ stats: ReceiverStats) {
        if ProcessInfo.processInfo.systemUptime - stageStart >= QualityTest.warmup { samples.append(stats.displayedFPS) }
    }

    private func next() {
        guard !stopped else { return }
        ticker?.cancel()
        ticker = nil
        if let streamer = streamer, index >= 0 {
            let bytes = streamer.takeCounters().bytes
            let fps = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            report.stages.append(QualityTest.Stage(size: configs[index].streamPixels, fps: fps,
                                                   gbps: Double(bytes) * 8 / (QualityTest.stageSeconds - QualityTest.warmup) / 1e9))
        }
        index += 1
        let old = streamer
        streamer = nil
        guard index < configs.count else {
            old?.stop()
            report.running = nil
            onReport?(report)
            onFinish?()
            return
        }
        // The next config may go out only after the previous stage's last frame
        guard let previous = old else { return begin(configs[index]) }
        previous.stop { [weak self] in DispatchQueue.main.async { self.map { $0.begin($0.configs[$0.index]) } } }
    }

    private func begin(_ config: StreamConfig) {
        guard !stopped, let message = try? JSONWire.message(.config, config),
              let streamer = try? FrameStreamer(config: config, capacityGbps: capacityGbps, connection: connection) else { return next() }
        connection.send(message)
        self.streamer = streamer
        samples = []
        stageStart = ProcessInfo.processInfo.systemUptime
        report.running = config.streamPixels
        onReport?(report)

        let size = config.streamPixels, start = stageStart, pattern = self.pattern
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        ticker.setEventHandler {
            if let frame = pattern.frame(size: size, time: ProcessInfo.processInfo.systemUptime - start) {
                streamer.offer(CapturedFrame(pixelBuffer: frame, dirty: nil))
            }
        }
        ticker.resume()
        self.ticker = ticker
        DispatchQueue.main.asyncAfter(deadline: .now() + QualityTest.warmup) { [weak self, weak streamer] in
            guard self?.streamer === streamer else { return }
            _ = streamer?.takeCounters()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + QualityTest.stageSeconds) { [weak self, weak streamer] in
            guard let self = self, self.streamer === streamer else { return }
            self.next()
        }
    }
}
