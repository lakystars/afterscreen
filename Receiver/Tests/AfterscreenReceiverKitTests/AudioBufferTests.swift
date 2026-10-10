import AfterscreenCore
import XCTest
@testable import AfterscreenReceiverKit

final class AudioJitterBufferTests: XCTestCase {
    private func pull(_ b: inout AudioJitterBuffer, _ frames: Int) -> [Int16] {
        var out = [Int16](repeating: 99, count: frames * 2)
        out.withUnsafeMutableBufferPointer { b.pull(into: $0, frames: frames) }
        return out
    }

    private func frames(_ range: ClosedRange<Int>) -> [Int16] { range.flatMap { [Int16($0), Int16($0)] } }

    func testSilenceUntilTheTargetIsBufferedThenPlaybackFromTheNewest() {
        var b = AudioJitterBuffer(channels: 2, target: 4, limit: 64)
        b.push(frames(1...3))
        XCTAssertEqual(pull(&b, 2), [0, 0, 0, 0], "3 frames are short of the 4-frame target")
        b.push(frames(4...5))
        XCTAssertEqual(pull(&b, 2), [2, 2, 3, 3], "from the newest 4 frames")
        XCTAssertEqual(b.bufferedFrames, 2)
    }

    func testUnderrunPlaysSilenceCountsItAndBuffersAgain() {
        var b = AudioJitterBuffer(channels: 2, target: 2, limit: 64)
        b.push(frames(1...3))
        XCTAssertEqual(pull(&b, 4), [2, 2, 3, 3, 0, 0, 0, 0])
        XCTAssertEqual(b.underruns, 1)
        b.push(frames(7...7))
        XCTAssertEqual(pull(&b, 1), [0, 0], "one frame does not refill the target")
        b.push(frames(8...8))
        XCTAssertEqual(pull(&b, 2), [7, 7, 8, 8])
    }

    func testFallingFarBehindDropsTheOldestDownToTheTarget() {
        var b = AudioJitterBuffer(channels: 2, target: 2, limit: 4)
        b.push(frames(1...6))
        XCTAssertEqual(b.bufferedFrames, 2)
        XCTAssertEqual(pull(&b, 2), [5, 5, 6, 6])
    }

    func testAFastSenderClockIsAbsorbedByPlayingSlightlyFasterWithoutSkips() {
        var b = AudioJitterBuffer(channels: 2, target: 1_000, limit: 100_000)
        let ramp = (0..<6_000).flatMap { [Int16($0 % 30_000), Int16($0 % 30_000)] }
        b.push(Array(ramp.prefix(2_000)))
        _ = pull(&b, 10)
        b.push(Array(ramp.dropFirst(2_000)))
        let before = b.bufferedFrames
        let out = pull(&b, 2_000)
        // Above twice the target the read rate is 0.2% fast: 2,000 frames out take about 2,004 in
        XCTAssertEqual(before - b.bufferedFrames, 2_004, accuracy: 1)
        // A ramp stays a ramp: interpolation, no jumps
        let steps = stride(from: 2, to: out.count, by: 2).map { Int(out[$0]) - Int(out[$0 - 2]) }
        XCTAssertTrue(steps.allSatisfy { (0...2).contains($0) }, "\(Set(steps))")
    }

    func testAFastReceiverClockIsAbsorbedByPlayingSlightlySlower() {
        var b = AudioJitterBuffer(channels: 2, target: 10_000, limit: 100_000)
        b.push(frames(1...12_000))
        _ = pull(&b, 7_000)
        // Below half the target the read rate is 0.2% slow: 2,500 frames out take about 2,495 in
        let before = b.bufferedFrames
        _ = pull(&b, 2_500)
        XCTAssertEqual(before - b.bufferedFrames, 2_495, accuracy: 1)
    }
}

final class AudioPlayerTests: XCTestCase {
    func testANewSampleRateMidStreamDoesNotDeadlock() {
        let player = AudioPlayer()
        let done = expectation(description: "played")
        DispatchQueue.global().async {
            let tenMs = [Int16](repeating: 0, count: 480 * 2)
            for _ in 0..<20 {
                player.play(AudioWire.Packet(sampleRate: 48_000, channels: 2, samples: tenMs))
                Thread.sleep(forTimeInterval: 0.01)
            }
            player.play(AudioWire.Packet(sampleRate: 44_100, channels: 2, samples: [Int16](repeating: 0, count: 441 * 2)))
            player.stop()
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
