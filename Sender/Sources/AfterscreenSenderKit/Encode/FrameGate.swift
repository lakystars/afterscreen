import Foundation

/// Paces frames to `interval`; holds the newest unsent one
struct FrameGate<Frame> {
    let interval: TimeInterval
    private(set) var pending: Frame?
    private var lastEmit = -Double.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// True when an unsent frame was replaced (dropped)
    @discardableResult
    mutating func offer(_ frame: Frame) -> Bool {
        let replaced = pending != nil
        pending = frame
        return replaced
    }

    /// Seconds until the gate opens
    func delay(now: TimeInterval) -> TimeInterval {
        max(0, lastEmit + interval - now)
    }

    mutating func take(now: TimeInterval, busy: Bool) -> Frame? {
        guard let frame = pending, !busy, now - lastEmit >= interval else { return nil }
        pending = nil
        lastEmit = now
        return frame
    }
}
