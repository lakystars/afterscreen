import Foundation

/// Video bitrate on a shared link
/// Backs off while the link queues, returns slowly
/// A download on the same Wi-Fi costs quality, not frames
struct RateControl {
    /// One second of streaming
    struct Sample: Equatable {
        /// Frames captured; a still screen proves nothing
        var frames: Int = 60
        /// Socket send rate this second
        var sentBps: Double = 0
        /// Kernel smoothed round trip; nil without TCP info
        var rttMs: Double?
        /// Least send buffer this second, in-flight included
        var buffered: Int = 0
        /// Receiver's window stalls the socket, not the link
        var receiverLimited = false
        /// A whole-screen frame went out: its burst is not a queue
        var fullFrame = false
    }

    /// RTT above the recent best: queueing on the way
    static let queueingMs = 30.0
    /// Loaded seconds the RTT baseline spans
    static let baseWindow = 30
    /// Stream time waiting in this Mac's socket
    static let drainLimit = 0.15
    /// Receiver window under this: the iMac is slow
    static let stalledWindow = 64 << 10
    /// Backlog shrinking less than this counts as stuck
    static let drainingShare = 0.97
    static let backoff = 0.7
    static let recovery = 1.1
    /// Clear seconds before the first step up
    static let clearSeconds = 3

    /// From the link probe; recovery stops here
    let start: Int
    let floor: Int
    private(set) var bitrate: Int
    private let fps: Double
    private var rtts: [Double] = []
    private var rttWasHigh = false
    /// Backlog while over the limit; cuts need time to drain
    private var draining: Int?
    private var clear = 0

    init(start: Int, fps: Double) {
        self.start = start
        floor = max(5_000_000, start / 8)
        bitrate = start
        self.fps = fps
    }

    /// Another link: the old RTT baseline and backlog mean nothing
    mutating func newLink() {
        rtts = []
        rttWasHigh = false
        draining = nil
        clear = 0
    }

    /// Once a second; the new bitrate, or nil when unchanged
    mutating func update(_ s: Sample) -> Int? {
        // Idle Wi-Fi power save raises RTT; nothing queues
        guard Double(s.frames) >= fps / 4 else {
            rttWasHigh = false
            draining = nil
            return nil
        }
        var rttHigh = false
        if let rtt = s.rttMs, rtt > 0, s.sentBps >= Double(bitrate) / 4 {
            rtts.append(rtt)
            if rtts.count > RateControl.baseWindow { rtts.removeFirst() }
            rttHigh = rtt - (rtts.min() ?? rtt) > RateControl.queueingMs
        }
        let over = !s.receiverLimited && !s.fullFrame && s.sentBps > 0
            && Double(s.buffered) * 8 / s.sentBps > RateControl.drainLimit
        // Cut again only while the backlog stays or grows
        let backlog = over && Double(s.buffered) >= Double(draining ?? 0) * RateControl.drainingShare
        draining = over ? s.buffered : nil
        // RTT alone must hold two seconds: Wi-Fi spikes pass
        let queued = backlog || (rttHigh && rttWasHigh)
        rttWasHigh = rttHigh
        let next: Int
        if queued {
            clear = 0
            next = max(floor, Int(Double(bitrate) * RateControl.backoff))
        } else if over {
            clear = 0
            return nil
        } else if rttHigh {
            // One spike: neither a cut nor a clear second
            return nil
        } else {
            clear += 1
            guard clear >= RateControl.clearSeconds else { return nil }
            next = min(start, Int(Double(bitrate) * RateControl.recovery))
        }
        guard next != bitrate else { return nil }
        bitrate = next
        return next
    }
}
