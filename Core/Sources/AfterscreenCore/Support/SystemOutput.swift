import AudioToolbox
import CoreAudio
import Foundation

/// Volume and mute of an output device
/// `volume`: the menu bar slider's scalar, 0…1
public struct OutputLevel: Equatable {
    public var volume: Double
    public var muted: Bool

    public init(volume: Double, muted: Bool) {
        self.volume = volume
        self.muted = muted
    }
}

/// One output across replugging
/// `source`: speakers or headphones of one built-in device
public struct OutputKey: Hashable {
    public var uid: String
    public var source: UInt32?

    public init(uid: String, source: UInt32?) {
        self.uid = uid
        self.source = source
    }
}

/// Default output device's volume and mute through the HAL
public struct SystemOutput {
    static let volume = AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    static let mute = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    static let source = AudioObjectPropertyAddress(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
    static let uid = AudioObjectPropertyAddress(kAudioDevicePropertyDeviceUID)
    static let defaultDevice = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    static let uidToDevice = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    public init() {}

    /// nil without an output device
    public var device: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard SystemOutput.get(SystemOutput.system, SystemOutput.defaultDevice, &id),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Default device's level; nil when its volume is fixed
    public var level: OutputLevel? { device.flatMap(level(of:)) }

    /// nil when the device has no adjustable volume, like HDMI
    public func level(of device: AudioObjectID) -> OutputLevel? {
        var address = SystemOutput.volume
        var settable: DarwinBoolean = false
        var volume = Float32(0), mute = UInt32(0)
        guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue, SystemOutput.get(device, address, &volume) else { return nil }
        // No main mute control counts as unmuted
        _ = SystemOutput.get(device, SystemOutput.mute, &mute)
        return OutputLevel(volume: Double(volume), muted: mute != 0)
    }

    public func key(of device: AudioObjectID) -> OutputKey? {
        var uid: Unmanaged<CFString>?
        guard SystemOutput.get(device, SystemOutput.uid, &uid), let id = uid?.takeRetainedValue() else { return nil }
        var source = UInt32(0)
        return OutputKey(uid: id as String, source: SystemOutput.get(device, SystemOutput.source, &source) ? source : nil)
    }

    /// Present device with that source active; nil otherwise
    public func device(for key: OutputKey) -> AudioObjectID? {
        var uid = key.uid as CFString
        var address = SystemOutput.uidToDevice
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(SystemOutput.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown, self.key(of: id) == key else { return nil }
        return id
    }

    public func set(_ level: OutputLevel, on device: AudioObjectID) {
        var volume = Float32(level.volume.isNaN ? 0 : min(1, max(0, level.volume))), mute = UInt32(level.muted ? 1 : 0)
        // Silent side first: no burst at the old volume
        if level.muted { SystemOutput.set(device, SystemOutput.mute, &mute) }
        SystemOutput.set(device, SystemOutput.volume, &volume)
        if !level.muted { SystemOutput.set(device, SystemOutput.mute, &mute) }
    }

    private static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T) -> Bool {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) } == noErr
    }

    private static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T) {
        var a = address
        withUnsafeMutablePointer(to: &value) { _ = AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }
}

/// Main queue callbacks on default output changes
/// `outputChanged`: new default device or data source
/// Otherwise its volume or mute changed
public final class OutputWatcher {
    private let levels: Bool
    private let onChange: (_ outputChanged: Bool) -> Void
    private var system: AudioListener?
    private var device: [AudioListener] = []

    /// `levels`: also report volume and mute changes
    public init(levels: Bool = true, onChange: @escaping (_ outputChanged: Bool) -> Void) {
        self.levels = levels
        self.onChange = onChange
        system = AudioListener(SystemOutput.system, SystemOutput.defaultDevice) { [weak self] in
            self?.bind()
            self?.onChange(true)
        }
        bind()
    }

    deinit { stop() }

    public func stop() {
        system?.remove()
        system = nil
        device.forEach { $0.remove() }
        device = []
    }

    private func bind() {
        device.forEach { $0.remove() }
        guard let id = SystemOutput().device else { return device = [] }
        // Headphone jack swaps the data source, not the device
        let source = AudioListener(id, SystemOutput.source) { [weak self] in self?.onChange(true) }
        // HAL may notify more than once per change
        let level = levels ? [SystemOutput.volume, SystemOutput.mute].compactMap { address in
            AudioListener(id, address) { [weak self] in self?.onChange(false) }
        } : []
        device = [source].compactMap { $0 } + level
    }
}

/// Property listener block on the main queue; `remove` detaches it
public struct AudioListener {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    /// nil when the object lacks the property
    public init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block) == noErr else { return nil }
        self.object = object
        self.address = address
        self.block = block
    }

    public func remove() {
        var a = address
        AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
    }
}

public extension AudioObjectPropertyAddress {
    /// Main element of `selector`
    init(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
