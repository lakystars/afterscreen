import XCTest
@testable import AfterscreenCore

final class LinkTelemetryTests: XCTestCase {
    private func facts(_ name: String, tb: Bool = false, ncm: Bool = false, wifi: Bool = false) -> InterfaceFacts {
        InterfaceFacts(name: name, isBridgeWithThunderbolt: tb, isUSBNCM: ncm, isWiFi: wifi, isLoopback: name.hasPrefix("lo"))
    }

    func testClassify() {
        XCTAssertEqual(LinkClassifier.classify(facts("bridge0", tb: true)), .thunderbolt)
        XCTAssertEqual(LinkClassifier.classify(facts("bridge100")), .unsupported)
        XCTAssertEqual(LinkClassifier.classify(facts("en5", ncm: true)), .usb)
        XCTAssertEqual(LinkClassifier.classify(facts("en0", wifi: true)), .wifi)
        XCTAssertEqual(LinkClassifier.classify(facts("lo0")), .loopback)
        XCTAssertEqual(LinkClassifier.classify(facts("en7")), .unsupported)
    }

    func testBridgeMemberParsing() {
        let output = """
        bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tConfiguration:
        \tmember: en1 flags=3<LEARNING,DISCOVER>
        \t        ifmaxaddr 0 port 9 priority 0 path cost 0
        \tmember: en2 flags=3<LEARNING,DISCOVER>
        \tstatus: active
        """
        XCTAssertEqual(LinkClassifier.bridgeMembers(ifconfigOutput: output), ["en1", "en2"])
    }

    func testLocalInterfacesReportLoopback() {
        XCTAssertEqual(LinkClassifier.classify(LinkClassifier.facts(for: "lo0")), .loopback)
    }

    func testCableScore() {
        XCTAssertEqual(CableScore.score(retransmitPercent: 0, jitterMs: 0, capacityGbps: 10, requiredGbps: 2.5), 100)
        XCTAssertEqual(CableScore.score(retransmitPercent: 1, jitterMs: 0, capacityGbps: 10, requiredGbps: 2.5), 96)
        XCTAssertEqual(CableScore.score(retransmitPercent: 0, jitterMs: 20, capacityGbps: 10, requiredGbps: 2.5), 70)
        XCTAssertEqual(CableScore.score(retransmitPercent: 0, jitterMs: 0, capacityGbps: 1.25, requiredGbps: 2.5), 85)
        XCTAssertEqual(CableScore.score(retransmitPercent: 0, jitterMs: 0, capacityGbps: nil, requiredGbps: 2.5), 100)
        XCTAssertEqual(CableScore.score(retransmitPercent: 50, jitterMs: 500, capacityGbps: 0, requiredGbps: 2.5), 0)
    }

    func testHistoryDropsOldest() {
        var h = History(capacity: 3)
        for v in [1.0, 2, 3, 4] { h.push(v) }
        XCTAssertEqual(h.values, [2, 3, 4])
        XCTAssertEqual(h.last, 4)
    }

    func testLatencyPercentiles() {
        var stats = LatencyStats(window: 40)
        for v in 1...20 { stats.add(ms: Double(v)) }
        XCTAssertEqual(stats.p50, 10.5, accuracy: 0.6)
        XCTAssertEqual(stats.p95, 19, accuracy: 1.1)
        XCTAssertEqual(stats.jitter, stats.p95 - stats.p50, accuracy: 0.001)
        var empty = LatencyStats(window: 4)
        XCTAssertEqual(empty.p50, 0)
        for v in [5.0, 5, 5, 5, 100] { empty.add(ms: v) }
        // Window holds the last 4: [5, 5, 5, 100], interpolated percentiles
        XCTAssertEqual(empty.p50, 5)
        XCTAssertEqual(empty.p95, 85.75, accuracy: 0.01)
    }

    func testProcessMetricsSanity() {
        let metrics = ProcessMetrics()
        _ = metrics.sample()
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }
        let s = metrics.sample()
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThanOrEqual(s.cpuPercent, 0)
        XCTAssertLessThan(s.cpuPercent, 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)
        XCTAssertGreaterThan(s.memoryBytes, 1 << 20)
    }

    func testGPUMeter() {
        let meter = GPUTimeMeter()
        _ = meter.percentSinceLastRead()
        meter.add(seconds: 0.001)
        Thread.sleep(forTimeInterval: 0.01)
        let p = meter.percentSinceLastRead()
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThanOrEqual(p, 100)
        XCTAssertEqual(meter.percentSinceLastRead(), 0, accuracy: 0.001)
    }

    func testFormat() {
        XCTAssertEqual(Format.gbps(bytesPerSecond: 2.41e9 / 8), "2.41 Gbps")
        XCTAssertEqual(Format.gbps(bytesPerSecond: 48e6 / 8), "48 Mbps")
        XCTAssertEqual(Format.bytes(182 << 20), "182 MB")
        XCTAssertEqual(Format.bytes(3 << 30), "3.0 GB")
    }
}

final class RateCounterTests: XCTestCase {
    func testRateIsSlidingAndReadingDoesNotReset() {
        let counter = RateCounter(window: 0.2)
        for _ in 0..<10 { counter.tick() }
        XCTAssertEqual(counter.ratePerSecond(), 50, accuracy: 0.01)
        XCTAssertEqual(counter.ratePerSecond(), 50, accuracy: 0.01)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(counter.ratePerSecond(), 0)
    }

    func testGPUMeterKeepsLastPercent() {
        let meter = GPUTimeMeter()
        _ = meter.percentSinceLastRead()
        meter.add(seconds: 0.002)
        Thread.sleep(forTimeInterval: 0.01)
        let p = meter.percentSinceLastRead()
        XCTAssertEqual(meter.lastPercent, p)
    }
}
