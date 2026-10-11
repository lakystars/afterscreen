import Foundation

/// When to tell the user the picture was turned down
/// Severe and lasting only: short dips pass unannounced
struct QualityNotice {
    /// At or under this share of the start: severe
    static let severeShare = 0.5
    static let severeSeconds = 5
    /// Back over this share this long: the episode ends
    static let recoveredShare = 0.9
    static let recoveredSeconds = 30
    /// Least time between two notices
    static let quietSeconds: TimeInterval = 600

    /// Severe long enough; ends once recovered
    private(set) var lowered = false
    private var severe = 0
    private var recovered = 0

    /// Once a second; true when the receiver shows the notice
    /// `lastShown` spans sessions: reconnects stay quiet too
    mutating func update(bitrate: Int, start: Int, now: TimeInterval, lastShown: inout TimeInterval?) -> Bool {
        guard start > 0 else { return false }
        let share = Double(bitrate) / Double(start)
        severe = share <= QualityNotice.severeShare ? severe + 1 : 0
        recovered = share >= QualityNotice.recoveredShare ? recovered + 1 : 0
        if lowered {
            if recovered >= QualityNotice.recoveredSeconds { lowered = false }
            return false
        }
        guard severe >= QualityNotice.severeSeconds else { return false }
        lowered = true
        if let last = lastShown, now - last < QualityNotice.quietSeconds { return false }
        lastShown = now
        return true
    }
}
