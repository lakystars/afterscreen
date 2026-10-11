import XCTest
@testable import AfterscreenSenderKit

final class RateControlTests: XCTestCase {
    /// A loaded second with nothing queued
    private let clear = RateControl.Sample(sentBps: 60e6, rttMs: 5)

    private func backlog(_ bytes: Int) -> RateControl.Sample {
        RateControl.Sample(sentBps: 40e6, rttMs: 5, buffered: bytes)
    }

    func testABacklogCutsOnceThenWaitsForItToDrain() {
        var c = RateControl(start: 80_000_000, fps: 60)
        XCTAssertNil(c.update(clear))
        XCTAssertEqual(c.update(backlog(2_000_000)), 56_000_000, "0.4 s waiting in the socket")
        XCTAssertNil(c.update(backlog(1_500_000)), "still over the limit but draining")
        XCTAssertEqual(c.update(backlog(1_600_000)), 39_200_000, "growing again")
        XCTAssertEqual(c.update(backlog(1_570_000)), 27_440_000, "a 2% shrink is a full buffer's jitter")
    }

    func testAWholeScreenFrameIsABurstNotAQueue() {
        var c = RateControl(start: 80_000_000, fps: 60)
        var refresh = backlog(3_000_000)
        refresh.fullFrame = true
        XCTAssertNil(c.update(refresh))
        XCTAssertNil(c.update(.init(sentBps: 0, rttMs: 5, buffered: 3_000_000)), "no send rate yet")
    }

    func testSingleSpikesDoNotStallRecovery() {
        var c = RateControl(start: 80_000_000, fps: 60)
        _ = c.update(clear)
        _ = c.update(backlog(2_000_000))
        let spike = RateControl.Sample(sentBps: 60e6, rttMs: 80)
        let steps = [clear, spike, clear, clear, spike, clear].map { c.update($0) }
        XCTAssertEqual(steps.compactMap { $0 }, [61_600_000, 67_760_000], "spikes neither cut nor reset the clear count")
    }

    func testTheReceiverWindowIsNotTheLink() {
        var c = RateControl(start: 80_000_000, fps: 60)
        var stalled = backlog(4_000_000)
        stalled.receiverLimited = true
        XCTAssertNil(c.update(stalled))
    }

    func testRoundTripsCountOnlyWhileDataFlows() {
        var c = RateControl(start: 80_000_000, fps: 60)
        _ = c.update(clear)
        XCTAssertNil(c.update(.init(sentBps: 60e6, rttMs: 60)), "one second high")
        XCTAssertEqual(c.update(.init(sentBps: 60e6, rttMs: 55)), 56_000_000, "two seconds high")
        var light = RateControl(start: 80_000_000, fps: 60)
        _ = light.update(clear)
        for _ in 0..<5 { XCTAssertNil(light.update(.init(sentBps: 5e6, rttMs: 100)), "sparse packets: power save, not a queue") }
    }

    func testTheBaselineForgetsAfterThirtySeconds() {
        var c = RateControl(start: 80_000_000, fps: 60)
        _ = c.update(clear)
        // A roam to a farther access point: RTT stays higher
        for _ in 0..<45 { _ = c.update(.init(sentBps: 60e6, rttMs: 50)) }
        XCTAssertGreaterThan(c.bitrate, c.floor, "recovering once 50 ms is the new best")
    }

    func testAStillScreenHoldsTheBitrate() {
        var c = RateControl(start: 80_000_000, fps: 60)
        _ = c.update(clear)
        XCTAssertNil(c.update(.init(frames: 2, sentBps: 1e6, rttMs: 100, buffered: 4_000_000)))
        XCTAssertNil(c.update(.init(frames: 2, sentBps: 1e6, rttMs: 100)))
    }

    func testFloorAndSlowRecovery() {
        var c = RateControl(start: 80_000_000, fps: 60)
        for i in 0..<20 { _ = c.update(backlog(2_000_000 + i)) }
        XCTAssertEqual(c.bitrate, 10_000_000, "an eighth of the start")
        XCTAssertNil(c.update(clear))
        XCTAssertNil(c.update(clear))
        XCTAssertEqual(c.update(clear), 11_000_000, "after three clear seconds")
        for _ in 0..<40 { _ = c.update(clear) }
        XCTAssertEqual(c.bitrate, 80_000_000, "back to the probe's rate, never above")
        XCTAssertEqual(RateControl(start: 20_000_000, fps: 60).floor, 5_000_000)
    }
}
