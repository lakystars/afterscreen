import Foundation

/// 0–100; 100 = clean link with headroom
public enum CableScore {
    public static func score(retransmitPercent: Double, jitterMs: Double, capacityGbps: Double?, requiredGbps: Double) -> Int {
        var score = 100.0
        score -= min(40, max(0, retransmitPercent) * 4)
        score -= min(30, max(0, jitterMs) * 3)
        if let capacity = capacityGbps, requiredGbps > 0 {
            score -= 30 * max(0, 1 - capacity / requiredGbps)
        }
        return max(0, min(100, Int(score.rounded())))
    }
}

/// Fixed-size sample history for sparklines
public struct History {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int) { self.capacity = capacity }

    public mutating func push(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var last: Double? { values.last }
    public var max: Double { values.max() ?? 0 }
}

/// Rolling round-trip samples; jitter = p95 − p50
public struct LatencyStats {
    public let window: Int
    private var samples: [Double] = []

    public init(window: Int = 40) { self.window = window }

    public mutating func add(ms: Double) {
        samples.append(ms)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    private func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }

    public var p50: Double { percentile(0.5) }
    public var p95: Double { percentile(0.95) }
    public var jitter: Double { p95 - p50 }
    public var last: Double? { samples.last }
}

/// Own GPU share of wall time, from command buffer timestamps
public final class GPUTimeMeter {
    private let lock = NSLock()
    private var busy = 0.0
    private var since = Date()
    private var last = 0.0

    public init() {}

    public func add(seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock()
        busy += seconds
        lock.unlock()
    }

    public func percentSinceLastRead() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let wall = now.timeIntervalSince(since)
        let p = wall > 0 ? min(100, busy / wall * 100) : 0
        busy = 0
        since = now
        last = p
        return p
    }

    /// Value returned by the last percentSinceLastRead
    public var lastPercent: Double {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Events per second over a sliding window; reads don't reset
public final class RateCounter {
    private let lock = NSLock()
    private let window: TimeInterval
    private var stamps: [TimeInterval] = []

    public init(window: TimeInterval = 1) { self.window = window }

    public func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        stamps.append(now)
        trim(now)
        lock.unlock()
    }

    public func ratePerSecond() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        trim(now)
        return Double(stamps.count) / window
    }

    private func trim(_ now: TimeInterval) {
        if let cut = stamps.firstIndex(where: { now - $0 <= window }) {
            if cut > 0 { stamps.removeFirst(cut) }
        } else {
            stamps.removeAll(keepingCapacity: true)
        }
    }
}

public enum Format {
    public static func gbps(bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1e9 { return String(format: "%.2f Gbps", bits / 1e9) }
        return String(format: "%.0f Mbps", bits / 1e6)
    }

    public static func bytes(_ b: UInt64) -> String {
        let mb = Double(b) / Double(1 << 20)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    public static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
    public static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v) }
}
