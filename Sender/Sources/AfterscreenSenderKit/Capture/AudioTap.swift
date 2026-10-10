import AudioToolbox
import CoreAudio
import Foundation

/// Float samples to interleaved 16-bit PCM, clipped to ±1
enum AudioConvert {
    static func interleave(_ planes: [UnsafeBufferPointer<Float>]) -> [Int16] {
        let frames = planes.map(\.count).min() ?? 0
        var out = [Int16](repeating: 0, count: frames * planes.count)
        for f in 0..<frames {
            for (c, plane) in planes.enumerated() { out[f * planes.count + c] = sample(plane[f]) }
        }
        return out
    }

    static func sample(_ x: Float) -> Int16 {
        Int16((min(1, max(-1, x)) * 32767).rounded())
    }
}

/// System-wide audio via a Core Audio process tap
/// Read through a private aggregate device holding only the tap
/// An output device with inputs (headset) would add its microphone
/// Mac output muted while tapped; sound plays only on receiver
/// Without System Audio Recording permission, the tap may deliver silence
@available(macOS 14.2, *)
final class AudioTap {
    typealias Handler = (_ sampleRate: Int, _ channels: Int, _ samples: [Int16]) -> Void

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "afterscreen.audio", qos: .userInteractive)

    /// `onSamples`: audio queue, about 10 ms of interleaved 16-bit samples
    /// `onChange`: main queue, on output device or tap format change
    /// Tap must then be rebuilt; nil when it cannot start
    init?(onSamples: @escaping Handler, onChange: @escaping () -> Void) {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Afterscreen"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioTap.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            stop()
            return nil
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Afterscreen",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate) == noErr else {
            stop()
            return nil
        }
        // 512 frames, about 10 ms
        // Receiver's 30 ms buffer expects packets of that order
        var frames: UInt32 = 512
        var framesAddress = AudioTap.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregate, &framesAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        let rate = Int(format.mSampleRate), channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if interleaved, let b = buffers.first, let data = b.mData {
                // Already in wire order
                let all = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4)
                return onSamples(rate, channels, all.map(AudioConvert.sample))
            }
            let planes = buffers.compactMap { b in
                b.mData.map { UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4) }
            }
            if !planes.isEmpty { onSamples(rate, planes.count, AudioConvert.interleave(planes)) }
        }) == noErr, AudioDeviceStart(aggregate, proc) == noErr else {
            stop()
            return nil
        }
        // New output device can change the tap's clock and format
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, onChange)
        listen(tap, kAudioTapPropertyFormat, onChange)
    }

    deinit { stop() }

    /// Unmutes the Mac's own output
    func stop() {
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners = []
        if let proc = proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ onChange: @escaping () -> Void) {
        var address = AudioTap.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
