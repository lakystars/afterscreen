import CoreVideo
import Metal
import XCTest
import AfterscreenCore
@testable import AfterscreenSenderKit

/// A handover moves frames between two connections in order
final class StreamHandoverTests: XCTestCase {
    /// Receiving side: message types per connection, in arrival order
    private final class Arrivals {
        private let lock = NSLock()
        private var log: [(link: Int, type: MessageType)] = []

        func add(_ link: Int, _ type: MessageType) {
            lock.lock()
            log.append((link, type))
            lock.unlock()
        }

        func types(on link: Int) -> [MessageType] {
            lock.lock()
            defer { lock.unlock() }
            return log.filter { $0.link == link }.map(\.type)
        }
    }

    /// Old and new connections to one listener: links 0, 1
    private struct Pair {
        let listener: Listener
        let old: Connection
        let next: Connection
        let arrivals: Arrivals

        func close() {
            old.close(reason: "test end")
            next.close(reason: "test end")
            listener.stop()
        }
    }

    private func pair() throws -> Pair {
        let listener = try Listener()
        let queue = DispatchQueue(label: "handover-peer")
        let arrivals = Arrivals()
        var accepted = 0
        listener.onAccept = { c in
            let link = queue.sync { () -> Int in accepted += 1; return accepted - 1 }
            c.onMessage = { arrivals.add(link, $0.type) }
            c.start(queue: queue)
        }
        listener.start()
        func connect(_ count: Int) throws -> Connection {
            var c: Connection?
            let done = expectation(description: "connect")
            Connection.connect(host: "127.0.0.1", port: listener.port, interfaceName: nil, timeout: 2) { c = try? $0.get(); done.fulfill() }
            wait(for: [done], timeout: 3)
            let connection = try XCTUnwrap(c)
            connection.start(queue: queue)
            XCTAssertTrue(until { queue.sync { accepted } == count })
            return connection
        }
        let old = try connect(1)
        return Pair(listener: listener, old: old, next: try connect(2), arrivals: arrivals)
    }

    private func until(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Every tile differs from the last frame: video carries motion
    private func frame(_ size: PixelSize, _ i: Int) throws -> CapturedFrame {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Row bands: real work for a video encoder
        for y in 0..<size.height { memset(base + y * stride, Int32((y * 7 + i * 31) % 256), stride) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CapturedFrame(pixelBuffer: buffer, dirty: nil)
    }

    private func stream(_ streamer: FrameStreamer, _ size: PixelSize, _ frames: Range<Int>) throws {
        for i in frames {
            streamer.offer(try frame(size, i))
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func testFramesMoveOnlyAfterTheSwitchoverIsRead() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "needs Metal")
        let p = try pair()
        defer { p.close() }
        let size = PixelSize(width: 256, height: 128)
        let streamer = try FrameStreamer(config: StreamConfig(path: .tile, streamPixels: size, video: nil, linkKind: .loopback),
                                         capacityGbps: 10, connection: p.old)
        defer { streamer.stop() }
        streamer.offer(try frame(size, 0))
        XCTAssertTrue(until { p.arrivals.types(on: 0).contains(.tileFrame) })

        streamer.switchConnection(to: p.next)
        streamer.offer(try frame(size, 1))
        XCTAssertTrue(until { p.arrivals.types(on: 0).contains(.switchover) })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(p.arrivals.types(on: 0).last, .switchover, "nothing follows the old connection's last message")
        XCTAssertFalse(p.arrivals.types(on: 1).contains(.tileFrame), "the new connection waits for the receiver's echo")

        streamer.finishSwitch(config: StreamConfig(path: .tile, streamPixels: size, video: nil, linkKind: .ethernet), capacityGbps: 0.95)
        XCTAssertTrue(until { p.arrivals.types(on: 1).contains(.tileFrame) }, "the held frame goes out on the new connection")
        XCTAssertEqual(p.arrivals.types(on: 1).first, .reconfigure, "the new link's config comes before any frame")
        XCTAssertEqual(p.arrivals.types(on: 0).last, .switchover)
    }

    /// Outputs the old encoder still owes arrive after the switch
    /// They must not ride on the new encoder's frames
    func testTheOldEncodersLateOutputsStayOffTheNewConnection() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "needs Metal")
        let p = try pair()
        defer { p.close() }
        // 240 fps: next frame encodes before the last returns
        let size = PixelSize(width: 1920, height: 1088)
        let first = StreamConfig(path: .hybrid, streamPixels: size, video: VideoLayer(codec: .hevc, pixels: size, bitrate: 60_000_000),
                                 linkKind: .wifi, frameRate: 240)
        let streamer = try FrameStreamer(config: first, capacityGbps: 0.2, connection: p.old)
        defer { streamer.stop() }
        try stream(streamer, size, 0..<12)
        XCTAssertTrue(until { p.arrivals.types(on: 0).contains(.videoFrame) }, "the old link carried video")
        // Back to back: old outputs still in flight
        streamer.offer(try frame(size, 12))
        streamer.offer(try frame(size, 13))
        streamer.switchConnection(to: p.next)
        var second = first
        second.video?.bitrate = 120_000_000
        second.linkKind = .ethernet
        streamer.finishSwitch(config: second, capacityGbps: 0.95)
        try stream(streamer, size, 14..<40)
        XCTAssertTrue(until { p.arrivals.types(on: 1).contains(.videoFrame) })
        let types = p.arrivals.types(on: 1)
        XCTAssertEqual(types.first, .reconfigure)
        let params = try XCTUnwrap(types.firstIndex(of: .videoParams), "the new encoder's keyframe brings its parameters")
        XCTAssertLessThan(params, try XCTUnwrap(types.firstIndex(of: .videoFrame)), "no old video ahead of the new parameters")
    }

    /// Onto a link fast enough for tiles: no video follows
    func testMovingFromVideoToTilesSendsNoMoreVideo() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "needs Metal")
        let p = try pair()
        defer { p.close() }
        let size = PixelSize(width: 1920, height: 1088)
        let hybrid = StreamConfig(path: .hybrid, streamPixels: size, video: VideoLayer(codec: .hevc, pixels: size, bitrate: 60_000_000),
                                  linkKind: .wifi, frameRate: 240)
        let streamer = try FrameStreamer(config: hybrid, capacityGbps: 0.2, connection: p.old)
        defer { streamer.stop() }
        try stream(streamer, size, 0..<12)
        XCTAssertTrue(until { p.arrivals.types(on: 0).contains(.videoFrame) })
        streamer.offer(try frame(size, 12))
        streamer.switchConnection(to: p.next)
        streamer.finishSwitch(config: StreamConfig(path: .tile, streamPixels: size, video: nil, linkKind: .thunderbolt, frameRate: 240),
                              capacityGbps: 12)
        try stream(streamer, size, 13..<30)
        XCTAssertTrue(until { p.arrivals.types(on: 1).filter { $0 == .tileFrame }.count >= 5 })
        Thread.sleep(forTimeInterval: 0.1)
        let types = p.arrivals.types(on: 1)
        XCTAssertEqual(types.first, .reconfigure)
        XCTAssertFalse(types.contains(.videoFrame) || types.contains(.videoParams), "a receiver on tiles ends a session at any video")
    }

    /// Onto a slower link: video starts with its parameters
    func testMovingFromTilesToVideoStartsAtAKeyframe() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "needs Metal")
        let p = try pair()
        defer { p.close() }
        let size = PixelSize(width: 1920, height: 1088)
        let tiles = StreamConfig(path: .tile, streamPixels: size, video: nil, linkKind: .thunderbolt, frameRate: 240)
        let streamer = try FrameStreamer(config: tiles, capacityGbps: 0.05, connection: p.old)
        defer { streamer.stop() }
        // Past the BC7 budget: moving tiles go out as BC1
        try stream(streamer, size, 0..<8)
        XCTAssertTrue(until { p.arrivals.types(on: 0).contains(.tileFrame) })
        streamer.switchConnection(to: p.next)
        let hybrid = StreamConfig(path: .hybrid, streamPixels: size, video: VideoLayer(codec: .hevc, pixels: size, bitrate: 60_000_000),
                                  linkKind: .wifi, frameRate: 240)
        streamer.finishSwitch(config: hybrid, capacityGbps: 0.2)
        try stream(streamer, size, 8..<30)
        XCTAssertTrue(until { p.arrivals.types(on: 1).contains(.videoFrame) }, "moving BC1 tiles move onto video")
        let types = p.arrivals.types(on: 1)
        XCTAssertEqual(types.first, .reconfigure)
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: .videoParams)), try XCTUnwrap(types.firstIndex(of: .videoFrame)))
    }
}
