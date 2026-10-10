import AppKit
import AfterscreenCore

/// 120 Hz while moving; 30 Hz after 0.5 s still
struct CursorPollRate {
    static let moving: TimeInterval = 1.0 / 120
    static let still: TimeInterval = 1.0 / 30
    static let stillPolls = 60

    private var unchanged = 0
    private(set) var interval = CursorPollRate.moving

    mutating func observe(moved: Bool) {
        unchanged = moved ? 0 : unchanged + 1
        interval = unchanged >= CursorPollRate.stillPolls ? CursorPollRate.still : CursorPollRate.moving
    }
}

/// Polls pointer position and image changes for one display
final class CursorTracker {
    var onPosition: ((Float, Float, Bool) -> Void)?
    var onImage: ((CursorImage) -> Void)?

    private let displayID: CGDirectDisplayID
    private var timer: DispatchSourceTimer?
    private var rate = CursorPollRate()
    private var lastPosition: (Float, Float, Bool)?
    private var lastImage: Int?
    private var lastSeed: Int32?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Quartz global coordinates (top-left origin); visible inside [min, max)
    static func normalize(point: CGPoint, displayBounds b: CGRect) -> (x: Float, y: Float, visible: Bool) {
        let visible = point.x >= b.minX && point.x < b.maxX && point.y >= b.minY && point.y < b.maxY
        guard b.width > 0, b.height > 0 else { return (0, 0, false) }
        return (Float((point.x - b.minX) / b.width), Float((point.y - b.minY) / b.height), visible)
    }

    /// Private CoreGraphics cursor image counter, about 2 µs
    /// `NSCursor.currentSystem` (about 300 µs) runs only on seed change
    static let seed: (@convention(c) () -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCurrentCursorSeed") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    /// Changes entirely off the display are not moves
    static func isMove(from old: (Float, Float, Bool), to new: (Float, Float, Bool)) -> Bool {
        (old.2 || new.2) && old != new
    }

    /// Smallest bitmap ≥ 2x for Retina receivers; else the largest
    static func bitmap(_ cursor: NSCursor) -> NSBitmapImageRep? {
        let want = Int(cursor.image.size.width * 2)
        let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
        return reps.filter { $0.pixelsWide >= want }.min { $0.pixelsWide < $1.pixelsWide }
            ?? reps.max { $0.pixelsWide < $1.pixelsWide }
    }

    /// Hash of hot spot, size and 2x pixels
    /// Cheap enough for every poll
    static func fingerprint(_ cursor: NSCursor) -> Int {
        var h = Hasher()
        h.combine(cursor.hotSpot.x)
        h.combine(cursor.hotSpot.y)
        h.combine(cursor.image.size.width)
        h.combine(cursor.image.size.height)
        if let rep = bitmap(cursor), let bytes = rep.bitmapData {
            h.combine(rep.pixelsWide)
            h.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        return h.finalize()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.poll() }
        schedule(timer)
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Sends the current image again on the next poll
    func resendImage() {
        lastImage = nil
        lastSeed = nil
    }

    private func schedule(_ timer: DispatchSourceTimer) {
        let interval = rate.interval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(interval > 0.02 ? 5 : 1))
    }

    private func poll() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let p = CursorTracker.normalize(point: location, displayBounds: CGDisplayBounds(displayID))
        let moved = lastPosition.map { CursorTracker.isMove(from: $0, to: p) } ?? true
        if moved {
            lastPosition = p
            onPosition?(p.x, p.y, p.visible)
        }
        let before = rate.interval
        rate.observe(moved: moved)
        if rate.interval != before, let timer = timer { schedule(timer) }
        if p.visible { pollImage() }
    }

    private func pollImage() {
        let seed = CursorTracker.seed?()
        guard seed == nil || seed != lastSeed, let cursor = NSCursor.currentSystem else { return }
        lastSeed = seed
        let print = CursorTracker.fingerprint(cursor)
        guard print != lastImage,
              let png = CursorTracker.bitmap(cursor)?.representation(using: .png, properties: [:]) else { return }
        lastImage = print
        let size = cursor.image.size
        onImage?(CursorImage(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                             hotX: Int(cursor.hotSpot.x.rounded()), hotY: Int(cursor.hotSpot.y.rounded()), png: png))
    }
}
