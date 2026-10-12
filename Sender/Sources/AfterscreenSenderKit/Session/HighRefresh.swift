import Foundation
import AfterscreenCore

/// 120 fps streams: an experiment, Thunderbolt only
/// When this Mac's tile encoder leaves half the frame free
public enum HighRefresh {
    public static let base = 60.0
    public static let ceiling = 120.0
    /// Share of a 120 fps frame the encoder may take
    static let encodeShare = 0.5
    static var budgetMs: Double { 1000 / ceiling * encodeShare }

    /// Shown under the frame counts while the experiment is on
    public enum Verdict: Equatable {
        case needsThunderbolt
        /// Lossless tiles at 120 fps need more than measured
        case linkTooSlow(gbps: Double)
        /// nil: the encoder could not be timed
        case encoderBusy(ms: Double?)
        case high(ms: Double)
    }

    /// Whether to time the encoder before choosing
    static func worthTiming(enabled: Bool, link: LinkKind, receiverHz: Double, tilesFit: Bool) -> Bool {
        enabled && link == .thunderbolt && receiverHz >= ceiling && tilesFit
    }

    /// nil: setting off, or a panel under 120 Hz
    static func verdict(enabled: Bool, link: LinkKind, receiverHz: Double, gbps: Double, tilesFit: Bool, encodeMs: Double?) -> Verdict? {
        guard enabled, receiverHz >= ceiling else { return nil }
        guard link == .thunderbolt else { return .needsThunderbolt }
        guard tilesFit else { return .linkTooSlow(gbps: gbps) }
        guard let ms = encodeMs, ms <= budgetMs else { return .encoderBusy(ms: encodeMs) }
        return .high(ms: ms)
    }

    static func maxFrameRate(_ verdict: Verdict?) -> Double {
        if case .high? = verdict { return ceiling }
        return base
    }
}
