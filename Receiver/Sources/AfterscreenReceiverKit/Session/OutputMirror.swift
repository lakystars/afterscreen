import AudioToolbox
import AfterscreenCore

/// Output device access; a fake in tests
protocol OutputControl {
    /// Default output device and its identity
    var current: (id: AudioObjectID, key: OutputKey)? { get }
    /// Present device with that source active
    func device(for key: OutputKey) -> AudioObjectID?
    func level(of device: AudioObjectID) -> OutputLevel?
    func set(_ level: OutputLevel, on device: AudioObjectID)
}

extension SystemOutput: OutputControl {
    var current: (id: AudioObjectID, key: OutputKey)? {
        guard let id = device, let key = key(of: id) else { return nil }
        return (id, key)
    }
}

/// iMac output takes the sender's volume and mute
/// Own level saved per output, restored when following ends
/// Main queue
final class OutputMirror {
    private let control: OutputControl
    private let watches: Bool
    /// Sender's level while following
    private var level: OutputLevel?
    /// Own levels of outputs now at the sender's level
    private var saved: [OutputKey: OutputLevel] = [:]
    /// Own levels waiting for their output to return
    /// For example, speakers while headphones are plugged in
    private var pending: [OutputKey: OutputLevel] = [:]
    private var watcher: OutputWatcher?

    /// `watches`: follow output changes; off in tests
    init(control: OutputControl = SystemOutput(), watches: Bool = true) {
        self.control = control
        self.watches = watches
    }

    /// nil restores the iMac's own levels
    func follow(_ level: OutputLevel?) {
        guard let level = level else { return restore() }
        self.level = level
        apply()
        watch()
    }

    func restore() {
        level = nil
        pending.merge(saved) { _, own in own }
        saved = [:]
        outputChanged()
    }

    /// New default device or data source
    func outputChanged() {
        for (key, own) in pending {
            guard let id = control.device(for: key) else { continue }
            control.set(own, on: id)
            pending[key] = nil
        }
        apply()
        watch()
    }

    private func apply() {
        guard let level = level, let (id, key) = control.current else { return }
        if saved[key] == nil {
            // Fixed-volume output: nothing to follow
            guard let own = pending.removeValue(forKey: key) ?? control.level(of: id) else { return }
            saved[key] = own
        }
        control.set(level, on: id)
    }

    /// Watches while following or while restores wait
    private func watch() {
        guard watches, level != nil || !pending.isEmpty else {
            watcher?.stop()
            watcher = nil
            return
        }
        if watcher == nil {
            watcher = OutputWatcher(levels: false) { [weak self] _ in self?.outputChanged() }
        }
    }
}
