import XCTest
@testable import AfterscreenCore

final class MessagesTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONWire.encode(value)
        XCTAssertEqual(try JSONWire.decode(T.self, from: data), value, file: file, line: line)
    }

    func testJSONRoundTrips() throws {
        try roundTrip(Hello(protocolVersion: 1, name: "MacBook", model: "Mac17,1", osVersion: "27.0"))
        try roundTrip(Welcome(protocolVersion: 1, name: "iMac", modelID: "iMac18,3", marketingName: "iMac 27\" 5K (2017)",
                              osVersion: "13.7", gpuNames: ["Radeon Pro 580", "Intel HD 630"],
                              panelPixels: PixelSize(width: 5120, height: 2880), panelPoints: PixelSize(width: 2560, height: 1440),
                              hevcDecode: true, h264Decode: true, bc7: true, hevcMain10Decode: true, channelToken: 7))
        try roundTrip(StreamConfig(path: .hybrid, streamPixels: PixelSize(width: 5120, height: 2880),
                                   video: VideoLayer(codec: .hevc, pixels: PixelSize(width: 3840, height: 2160), bitrate: 160_000_000, tenBit: true),
                                   linkKind: .wifi))
        try roundTrip(StreamConfig(path: .tile, streamPixels: PixelSize(width: 5120, height: 2880),
                                   video: nil, linkKind: .ethernet))
        try roundTrip(ReceiverStats(receivedFPS: 60, displayedFPS: 59.5, uploadMs: 1.2, decompressMs: 2.3, lateFrames: 1,
                                    cpuPercent: 9.5, memoryBytes: 123_456_789, gpuPercent: 18, brightness: 0.7))
        try roundTrip(ReceiverStats(receivedFPS: 60, displayedFPS: 59.5, uploadMs: 1.2, decompressMs: 2.3, lateFrames: 1,
                                    cpuPercent: 9.5, memoryBytes: 123_456_789, gpuPercent: 18, brightness: nil))
        try roundTrip(Bye(reason: "user"))
        try roundTrip(Bye(reason: "Stopped on the receiver", pause: true))
        try roundTrip(ProbeResult(bytes: 1 << 20, seconds: 0.3))
    }

    func testCursorWireRoundTrip() throws {
        let pos = try CursorWire.parsePos(CursorWire.pos(x: 0.25, y: 0.75, visible: true))
        XCTAssertEqual(pos.x, 0.25)
        XCTAssertEqual(pos.y, 0.75)
        XCTAssertTrue(pos.visible)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = try CursorWire.parseImage(CursorWire.image(width: 17, height: 23, hotX: 4, hotY: 5, png: png))
        XCTAssertEqual(image, CursorImage(width: 17, height: 23, hotX: 4, hotY: 5, png: png))
    }

    func testTruncatedCursorThrows() {
        XCTAssertThrowsError(try CursorWire.parsePos(Data([1, 2, 3])))
        XCTAssertThrowsError(try CursorWire.parseImage(Data([1, 0, 2])))
    }

    func testChannelTokenRoundTrip() throws {
        XCTAssertEqual(try ChannelWire.decode(ChannelWire.encode(0xDEAD_BEEF)), 0xDEAD_BEEF)
        XCTAssertThrowsError(try ChannelWire.decode(Data([1])))
    }

    func testLevelWireClampsToTheUnitRange() throws {
        XCTAssertEqual(try LevelWire.decode(LevelWire.encode(0.25)), 0.25)
        XCTAssertEqual(try LevelWire.decode(LevelWire.encode(1.7)), 1)
        XCTAssertEqual(try LevelWire.decode(LevelWire.encode(-1)), 0)
        XCTAssertEqual(try LevelWire.decode(LevelWire.encode(.nan)), 0)
        XCTAssertThrowsError(try LevelWire.decode(Data([1, 2])))
    }

    func testPingRoundTripAndTruncation() throws {
        XCTAssertEqual(try PingWire.decode(PingWire.encode(123_456_789_012)), 123_456_789_012)
        XCTAssertThrowsError(try PingWire.decode(Data([1, 2])))
    }
}

final class VideoWireTests: XCTestCase {
    func testParamsAndFrameRoundTrip() throws {
        let sets = [Data([1, 2, 3]), Data([4]), Data(repeating: 9, count: 300)]
        let parsed = try VideoWire.parseParams(VideoWire.params(codec: .h264, sets: sets))
        XCTAssertEqual(parsed.codec, .h264)
        XCTAssertEqual(parsed.sets, sets)
        let frame = try VideoWire.parseFrame(VideoWire.frame(keyframe: true, avcc: Data([7, 7])))
        XCTAssertTrue(frame.keyframe)
        XCTAssertEqual(frame.avcc, Data([7, 7]))
        XCTAssertThrowsError(try VideoWire.parseParams(Data([0, 1, 5, 0, 0, 0])))
    }
}

final class L10nTests: XCTestCase {
    func testSystemFollowsTheFirstPreferredLanguage() {
        XCTAssertTrue(L10n.isKorean(.system, preferred: ["ko-KR", "en-US"]))
        XCTAssertFalse(L10n.isKorean(.system, preferred: ["en-US", "ko-KR"]))
        XCTAssertFalse(L10n.isKorean(.system, preferred: []))
        XCTAssertTrue(L10n.isKorean(.korean, preferred: ["en-US"]))
        XCTAssertFalse(L10n.isKorean(.english, preferred: ["ko-KR"]))
    }

    func testTranslationPicksTheChosenLanguage() {
        let saved = L10n.language
        defer { L10n.language = saved }
        L10n.language = .korean
        XCTAssertEqual(L10n.t("Throughput", "전송량"), "전송량")
        L10n.language = .english
        XCTAssertEqual(L10n.t("Throughput", "전송량"), "Throughput")
    }
}

final class AudioWireTests: XCTestCase {
    func testPacketRoundTrip() throws {
        let samples: [Int16] = [1, -1, 300, -300, 32767, -32768]
        let packet = try AudioWire.decode(AudioWire.encode(sampleRate: 48_000, channels: 2, samples: samples))
        XCTAssertEqual(packet.sampleRate, 48_000)
        XCTAssertEqual(packet.channels, 2)
        XCTAssertEqual(packet.samples, samples)
    }

    func testMalformedPacketsAreRejected() {
        XCTAssertThrowsError(try AudioWire.decode(AudioWire.encode(sampleRate: 48_000, channels: 3, samples: [0, 0, 0])))
        XCTAssertThrowsError(try AudioWire.decode(AudioWire.encode(sampleRate: 1_000, channels: 2, samples: [0, 0])))
        var odd = AudioWire.encode(sampleRate: 48_000, channels: 2, samples: [0, 0])
        odd.append(1)
        XCTAssertThrowsError(try AudioWire.decode(odd), "half a sample")
        XCTAssertThrowsError(try AudioWire.decode(AudioWire.encode(sampleRate: 48_000, channels: 2, samples: [0])), "half a frame")
    }
}
