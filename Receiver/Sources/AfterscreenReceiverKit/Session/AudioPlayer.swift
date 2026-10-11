import AudioToolbox
import Foundation
import AfterscreenCore

/// Interleaved 16-bit frames between the network and the audio queue
/// Silence until `target` frames are buffered, again after an underrun
/// Playback then starts from the newest `target` frames
/// Above `target` + `catchUpMargin`: 0.2% fast; below half: 0.2% slow
/// Interpolates between frames, so clock drift either way
/// causes neither skipped samples (crackle) nor underruns
/// Past `limit` (`target` + `trimMargin`): oldest dropped to `target`
/// Fixed margins: a grown target adds no extra lag
/// Each underrun grows `target` by half, up to `maxTarget`
/// `calmFrames` played without one shrink it a tenth
/// Cables stay at the floor; Wi-Fi jitter buys itself room
struct AudioJitterBuffer {
    static let catchUp = 1.002
    static let holdBack = 0.998

    let channels: Int
    let minTarget: Int
    let maxTarget: Int
    let calmFrames: Int
    private(set) var target: Int
    let catchUpMargin: Int
    let trimMargin: Int
    var limit: Int { target + trimMargin }
    /// Frames played since the last underrun or shrink
    private var calm = 0
    private(set) var underruns = 0
    private var samples: [Int16] = []
    private var head = 0
    /// Read position between frame `head` and the next
    private var phase = 0.0
    private var primed = false

    init(channels: Int, target: Int, limit: Int, maxTarget: Int? = nil, calmFrames: Int = .max) {
        self.channels = channels
        minTarget = target
        self.maxTarget = max(target, maxTarget ?? target)
        self.target = target
        // As first built: catch up past twice the target
        catchUpMargin = target
        trimMargin = max(1, limit - target)
        self.calmFrames = calmFrames
    }

    var bufferedFrames: Int { (samples.count - head) / channels }

    mutating func push(_ new: [Int16]) {
        samples.append(contentsOf: new)
        if bufferedFrames > limit { restart() }
        // Reclaim the consumed front once it outgrows what is left
        if head > samples.count - head {
            samples.removeFirst(head)
            head = 0
        }
    }

    mutating func pull(into out: UnsafeMutableBufferPointer<Int16>, frames: Int) {
        if !primed {
            guard bufferedFrames >= target else { return out.update(repeating: 0) }
            primed = true
            restart()
        }
        let level = bufferedFrames
        let step = level > target + catchUpMargin ? AudioJitterBuffer.catchUp : (level < target / 2 ? AudioJitterBuffer.holdBack : 1)
        var written = 0
        while written < frames {
            let available = bufferedFrames
            // Between two frames the next one must be here too
            guard available > 0, phase == 0 || available > 1 else { break }
            for c in 0..<channels {
                let a = Double(samples[head + c])
                let v = phase == 0 ? a : a + (Double(samples[head + channels + c]) - a) * phase
                out[written * channels + c] = Int16(v.rounded())
            }
            written += 1
            phase += step
            let whole = min(Int(phase), available)
            head += whole * channels
            phase -= Double(whole)
        }
        guard written < frames else { return settle(frames) }
        for i in (written * channels)..<(frames * channels) { out[i] = 0 }
        primed = false
        underruns += 1
        target = min(maxTarget, target + max(1, target / 2))
        calm = 0
    }

    private mutating func settle(_ played: Int) {
        calm += played
        guard calm >= calmFrames, target > minTarget else { return }
        target = max(minTarget, target - max(1, target / 10))
        calm = 0
    }

    private mutating func restart() {
        head = samples.count - target * channels
        phase = 0
    }
}

/// Plays sender audio via an AudioQueue and a jitter buffer
final class AudioPlayer {
    /// Buffered before playback: room for network and busy receiver
    static let targetSeconds = 0.03
    /// Ceiling the target grows to after underruns
    static let maxTargetSeconds = 0.15
    /// Buffered this far past the target, the oldest drop
    static let trimSeconds = 0.12
    /// Played this long without an underrun, the target shrinks
    static let calmSeconds = 30.0
    /// Three queue buffers of 10 ms
    static let bufferSeconds = 0.01

    private let lock = NSLock()
    private var buffer: AudioJitterBuffer?
    private var queue: AudioQueueRef?
    private var format: (rate: Int, channels: Int)?

    deinit { stop() }

    /// Any thread
    func play(_ packet: AudioWire.Packet) {
        lock.lock()
        guard format.map({ $0 != (packet.sampleRate, packet.channels) }) ?? true else {
            buffer?.push(packet.samples)
            return lock.unlock()
        }
        let old = queue
        queue = nil
        lock.unlock()
        // Outside the lock: dispose waits on the callback, which locks
        dispose(old)
        lock.lock()
        start(rate: packet.sampleRate, channels: packet.channels)
        buffer?.push(packet.samples)
        lock.unlock()
    }

    private func dispose(_ q: AudioQueueRef?) {
        guard let q = q else { return }
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
    }

    /// Underrun count since the stream began, for telemetry
    var underruns: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer?.underruns ?? 0
    }

    /// Buffered sound in seconds, for telemetry
    var bufferedSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let b = buffer, let f = format else { return nil }
        return Double(b.bufferedFrames) / Double(f.rate)
    }

    func stop() {
        lock.lock()
        let q = queue
        queue = nil
        buffer = nil
        format = nil
        lock.unlock()
        dispose(q)
    }

    /// Under the lock, with no queue running
    private func start(rate: Int, channels: Int) {
        format = (rate, channels)
        let target = Int(Double(rate) * AudioPlayer.targetSeconds)
        buffer = AudioJitterBuffer(channels: channels, target: target, limit: target + Int(Double(rate) * AudioPlayer.trimSeconds),
                                   maxTarget: Int(Double(rate) * AudioPlayer.maxTargetSeconds), calmFrames: Int(Double(rate) * AudioPlayer.calmSeconds))
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard AudioQueueNewOutput(&asbd, { context, queue, buffer in
            Unmanaged<AudioPlayer>.fromOpaque(context!).takeUnretainedValue().fill(buffer, queue: queue)
        }, me, nil, nil, 0, &q) == noErr, let created = q else { return }
        let frames = Int(Double(rate) * AudioPlayer.bufferSeconds)
        for _ in 0..<3 {
            var b: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(created, UInt32(frames * 2 * channels), &b) == noErr, let buffer = b else { continue }
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
            memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
            AudioQueueEnqueueBuffer(created, buffer, 0, nil)
        }
        // Full gain: the iMac's output carries the sender's volume
        queue = created
        AudioQueueStart(created, nil)
    }

    /// Audio queue thread: refills played buffers from the jitter buffer
    private func fill(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        lock.lock()
        let frames = Int(buffer.pointee.mAudioDataBytesCapacity) / (2 * (format?.channels ?? 2))
        let out = UnsafeMutableBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self),
                                             count: frames * (format?.channels ?? 2))
        if self.queue == queue, self.buffer != nil {
            self.buffer!.pull(into: out, frames: frames)
        } else {
            out.update(repeating: 0)
        }
        lock.unlock()
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}
