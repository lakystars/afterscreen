import AppKit
import AfterscreenCore

/// The panel's own resolution while a stream shows
/// A scaled mode resamples the stream a second time
final class PanelMode {
    private var switched: (id: CGDirectDisplayID, original: CGDisplayMode)?

    /// The mode drawing `panel` 1:1: HiDPI first, then same refresh
    /// nil when `current` already does, or no mode does
    static func nativeMode(_ modes: [DisplayModeInfo], panel: PixelSize, current: DisplayModeInfo) -> Int? {
        let drawsPanel = { (m: DisplayModeInfo) in m.pixelWidth == panel.width && m.pixelHeight == panel.height }
        guard !drawsPanel(current) else { return nil }
        return modes.indices.filter { drawsPanel(modes[$0]) }.max { a, b in
            let rank = { (m: DisplayModeInfo) in (m.width * 2 == m.pixelWidth ? 2 : 0) + (m.refreshRate == current.refreshRate ? 1 : 0) }
            let (ra, rb) = (rank(modes[a]), rank(modes[b]))
            return ra != rb ? ra < rb : modes[a].refreshRate < modes[b].refreshRate
        }
    }

    /// The mode `match` switches to; nil when none is needed
    static func target(_ id: CGDirectDisplayID) -> CGDisplayMode? {
        guard let current = CGDisplayCopyDisplayMode(id) else { return nil }
        let modes = HardwareInfo.displayModes(id).filter { $0.isUsableForDesktopGUI() }
        let panel = HardwareInfo.panelPixels(id)
        return nativeMode(modes.map(HardwareInfo.info), panel: panel, current: HardwareInfo.info(current)).map { modes[$0] }
    }

    /// Main queue, before the window opens
    /// The new mode's size in points; screen frames follow it
    func match(_ id: CGDirectDisplayID) -> CGSize? {
        if switched.map({ $0.id != id }) == true { restore() }
        guard switched == nil, let current = CGDisplayCopyDisplayMode(id), let mode = PanelMode.target(id),
              PanelMode.apply(mode, to: id) else { return nil }
        switched = (id, current)
        return CGSize(width: mode.width, height: mode.height)
    }

    /// Main queue, once the window has closed
    func restore() {
        guard let s = switched else { return }
        switched = nil
        _ = PanelMode.apply(s.original, to: s.id)
    }

    /// This app only: restored by macOS when it quits
    private static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}
