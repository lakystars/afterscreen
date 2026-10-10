import CoreGraphics

/// macOS mirroring of this Mac's display into the virtual display
/// The virtual display leads: the desktop takes the iMac's shape
/// This Mac's panel shows it letterboxed
/// Undone by `stop`, or by macOS as the virtual display goes
/// macOS restores earlier mirror sets for a returning display
final class DisplayMirror {
    let source: CGDirectDisplayID
    private var active = true

    /// Last refusal, for the log
    static var lastError: String?

    /// nil when macOS refuses the configuration
    init?(source: CGDirectDisplayID, into target: CGDirectDisplayID) {
        self.source = source
        // Restored by macOS: already in place
        guard CGDisplayMirrorsDisplay(source) == target || DisplayMirror.configure(source, mirrorOf: target) else { return nil }
    }

    deinit { stop() }

    func stop() {
        guard active else { return }
        active = false
        _ = DisplayMirror.configure(source, mirrorOf: kCGNullDirectDisplay)
    }

    /// Display to copy: one already mirroring the target, else main,
    /// else built-in, else any other
    /// Never the target, even if an old arrangement made it main
    static func source(online: [CGDirectDisplayID], active: [CGDirectDisplayID], main: CGDirectDisplayID,
                       builtIn: (CGDirectDisplayID) -> Bool, mirrorOf: (CGDirectDisplayID) -> CGDirectDisplayID,
                       excluding target: CGDirectDisplayID) -> CGDirectDisplayID? {
        if let restored = online.first(where: { $0 != target && mirrorOf($0) == target }) { return restored }
        let others = active.filter { $0 != target }
        if others.contains(main) { return main }
        return others.first(where: builtIn) ?? others.first
    }

    static func source(excluding target: CGDirectDisplayID) -> CGDirectDisplayID? {
        source(online: displays(CGGetOnlineDisplayList), active: displays(CGGetActiveDisplayList), main: CGMainDisplayID(),
               builtIn: { CGDisplayIsBuiltin($0) != 0 }, mirrorOf: CGDisplayMirrorsDisplay, excluding: target)
    }

    /// Extend: undoes a mirror set macOS restored for `target`
    /// true when one was found
    @discardableResult
    static func release(_ target: CGDirectDisplayID) -> Bool {
        let mirrored = displays(CGGetOnlineDisplayList).filter { CGDisplayMirrorsDisplay($0) == target }
        let leading = CGDisplayMirrorsDisplay(target)
        mirrored.forEach { _ = configure($0, mirrorOf: kCGNullDirectDisplay) }
        if leading != kCGNullDirectDisplay { _ = configure(target, mirrorOf: kCGNullDirectDisplay) }
        return !mirrored.isEmpty || leading != kCGNullDirectDisplay
    }

    private static func displays(_ list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard list(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard list(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Login session only: nothing outlives a logout
    private static func configure(_ display: CGDirectDisplayID, mirrorOf master: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config = config else {
            lastError = "begin \(begin.rawValue)"
            return false
        }
        let mirror = CGConfigureDisplayMirrorOfDisplay(config, display, master)
        guard mirror == .success else {
            CGCancelDisplayConfiguration(config)
            lastError = "mirror \(mirror.rawValue)"
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        lastError = complete == .success ? nil : "complete \(complete.rawValue)"
        return complete == .success
    }
}
