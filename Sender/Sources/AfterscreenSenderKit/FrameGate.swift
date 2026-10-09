import Foundation

/// Paces frames to `interval` and holds the newest unsent one until it can go out
struct FrameGate<Frame> {
    let interval: TimeInterval
    private(set) var pending: Frame?
    private var lastEmit = -Double.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Returns true when an unsent frame was replaced (a dropped frame)
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
