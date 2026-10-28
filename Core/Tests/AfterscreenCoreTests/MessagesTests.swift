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
                                    cpuPercent: 9.5, memoryBytes: 123_456_789, gpuPercent: 18, audioBufferMs: 30, audioUnderruns: 0,
                                    shown: false))
        try roundTrip(ReceiverStats(receivedFPS: 60, displayedFPS: 59.5, uploadMs: 1.2, decompressMs: 2.3, lateFrames: 1,
                                    cpuPercent: 9.5, memoryBytes: 123_456_789, gpuPercent: 18))
        try roundTrip(SenderStats(interface: "bridge0", capacityGbps: 12.4, throughputBitsPerSecond: 754e6,
                                  latencyMs: 1.0, jitterMs: 0.1, retransmitPercent: 0, cableScore: 100,
                                  captureFPS: 60, sentFPS: 60, droppedPerMinute: 0, dirtyPercent: 11, compressionRatio: 1,
                                  encodeMs: 2.6, lossyTiles: 0, cpuPercent: 13, memoryBytes: 196 << 20, gpuPercent: 16))
        try roundTrip(SenderStats(interface: nil, capacityGbps: nil, throughputBitsPerSecond: 0,
                                  latencyMs: nil, jitterMs: 0, retransmitPercent: 0, cableScore: nil,
                                  captureFPS: 0, sentFPS: 0, droppedPerMinute: 0, dirtyPercent: 0, compressionRatio: 0,
                                  encodeMs: 0, lossyTiles: 0, cpuPercent: 0, memoryBytes: 0, gpuPercent: 0))
        var busy = SenderStats(interface: nil, capacityGbps: 0.2, throughputBitsPerSecond: 0,
                               latencyMs: nil, jitterMs: 0, retransmitPercent: 0, cableScore: nil,
                               captureFPS: 0, sentFPS: 0, droppedPerMinute: 0, dirtyPercent: 0, compressionRatio: 0,
                               encodeMs: 0, lossyTiles: 0, cpuPercent: 0, memoryBytes: 0, gpuPercent: 0)
        busy.congestionNotice = true
        try roundTrip(busy)
        try roundTrip(Bye(reason: "user"))
        try roundTrip(Bye(reason: "Stopped on the receiver", pause: true))
        try roundTrip(Bye(reason: "Switching to Ethernet", relink: true))
        try roundTrip(ProbeResult(bytes: 1 << 20, seconds: 0.3))
    }

    func testStatsFromAnOlderSenderStillRead() throws {
        let sent = try JSONWire.encode(SenderStats(
            interface: "bridge0", capacityGbps: 12.4, throughputBitsPerSecond: 754e6, latencyMs: 1, jitterMs: 0.1,
            retransmitPercent: 0, cableScore: 100, captureFPS: 60, sentFPS: 60, droppedPerMinute: 0, dirtyPercent: 11,
            compressionRatio: 1, encodeMs: 2.6, lossyTiles: 0, cpuPercent: 13, memoryBytes: 196 << 20, gpuPercent: 16))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        json["mtu"] = 1500
        let stats = try JSONWire.decode(SenderStats.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(stats.interface, "bridge0")
    }

    func testByeWithoutRelinkReadsAsAnEnd() throws {
        let bye = try JSONWire.decode(Bye.self, from: Data(#"{"reason":"x","pause":false}"#.utf8))
        XCTAssertFalse(bye.relink)
    }

    func testByeCarriesTheReceiversPower() throws {
        try roundTrip(Bye(reason: "Stopped on MBP", power: .shutDown))
        XCTAssertNil(try JSONWire.decode(Bye.self, from: Data(#"{"reason":"x"}"#.utf8)).power, "an older sender asks nothing")
        let newer = try JSONWire.decode(Bye.self, from: Data(#"{"reason":"x","power":"hibernate"}"#.utf8))
        XCTAssertEqual(newer.reason, "x")
        XCTAssertNil(newer.power, "an unknown request is ignored, the rest kept")
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

    func testBrightnessWireCarriesNitsWhenKnownAndTheLevel() throws {
        let light = try BrightnessWire.decode(BrightnessWire.encode(PanelLight(nits: 259.7, level: 0.5625)))
        XCTAssertEqual(light.nits ?? 0, 259.7, accuracy: 1e-3)
        XCTAssertEqual(light.level, 0.5625, accuracy: 1e-6)
        XCTAssertNil(try BrightnessWire.decode(BrightnessWire.encode(PanelLight(nits: nil, level: 0.3))).nits, "unknown peak: level only")
        XCTAssertNil(try BrightnessWire.decode(BrightnessWire.encode(PanelLight(nits: .nan, level: 0.3))).nits)
        XCTAssertEqual(try BrightnessWire.decode(BrightnessWire.encode(PanelLight(nits: 1e6, level: 7))).level, 1)
        XCTAssertThrowsError(try BrightnessWire.decode(Data([1, 2, 3, 4])))
    }

    func testOutputLevelWireRoundTripsAndClamps() throws {
        let level = OutputLevel(volume: 0.4375, muted: true)
        XCTAssertEqual(try OutputLevelWire.decode(OutputLevelWire.encode(level)), level)
        XCTAssertEqual(try OutputLevelWire.decode(OutputLevelWire.encode(OutputLevel(volume: 1.7, muted: false)))?.volume, 1)
        XCTAssertEqual(try OutputLevelWire.decode(OutputLevelWire.encode(OutputLevel(volume: .nan, muted: false)))?.volume, 0)
        XCTAssertTrue(OutputLevelWire.encode(nil).isEmpty, "empty hands the level back")
        XCTAssertNil(try OutputLevelWire.decode(Data()))
        XCTAssertThrowsError(try OutputLevelWire.decode(Data([0, 0, 0, 0])))
    }

    func testPingRoundTripAndTruncation() throws {
        XCTAssertEqual(try PingWire.decode(PingWire.encode(123_456_789_012)), 123_456_789_012)
        XCTAssertThrowsError(try PingWire.decode(Data([1, 2])))
    }

    private let options = ReceiverOptions(editable: true, hud: false, presentation: .space,
                                          screens: [ReceiverOptions.Screen(key: "imac", name: "iMac", pixels: PixelSize(width: 5120, height: 2880))],
                                          screen: "gone", missingScreen: "LG", matchPanelMode: true, effect: .tiles,
                                          onDisconnect: .showDesktop, launchAtLogin: false)

    func testReceiverOptionsRoundTrip() throws {
        try roundTrip(options)
        try roundTrip(Hello(protocolVersion: 1, name: "MacBook", model: "Mac17,1", osVersion: "27.0", readsOptions: true))
    }

    func testAnOptionsEditCarriesOnlyItsFields() throws {
        XCTAssertEqual(String(decoding: try JSONWire.encode(ReceiverOptionsChange(hud: true)), as: UTF8.self), #"{"hud":true}"#)
        try roundTrip(ReceiverOptionsChange(presentation: .cover, screen: "", effect: .tiles))
    }

    func testANewerSendersValueIsSkippedNotTheEdit() throws {
        let edit = try JSONWire.decode(ReceiverOptionsChange.self, from: Data(#"{"hud":true,"effect":"sparkle","matchPanelMode":"yes"}"#.utf8))
        XCTAssertEqual(edit, ReceiverOptionsChange(hud: true))
    }

    func testAReopenByeAsksTheSenderBack() throws {
        try roundTrip(Bye(reason: "Applying", relink: true, reopen: true))
        XCTAssertNil(try JSONWire.decode(Bye.self, from: Data(#"{"reason":"older"}"#.utf8)).reopen)
    }

    func testAnEditAppliesToTheOptionsShown() {
        let automatic = options.applying(ReceiverOptionsChange(screen: ""))
        XCTAssertNil(automatic.screen)
        XCTAssertNil(automatic.missingScreen, "automatic misses no screen")
        let picked = options.applying(ReceiverOptionsChange(screen: "imac"))
        XCTAssertEqual(picked.screen, "imac")
        XCTAssertNil(picked.missingScreen)
        XCTAssertEqual(options.applying(ReceiverOptionsChange(screen: "other")), options, "a screen not listed changes nothing")
        // Spelled out: a bare .none is the optional's nil
        let all = options.applying(ReceiverOptionsChange(hud: true, presentation: .cover, matchPanelMode: false, effect: ReceiverOptions.Effect.none,
                                                         onDisconnect: .sleepDisplay, launchAtLogin: true))
        XCTAssertEqual([all.hud, all.matchPanelMode, all.launchAtLogin], [true, false, true])
        XCTAssertEqual(all.presentation, .cover)
        XCTAssertEqual(all.effect, ReceiverOptions.Effect.none)
        XCTAssertEqual(all.onDisconnect, .sleepDisplay)
        XCTAssertEqual(all.screen, "gone", "untouched fields stay")
    }
}

final class VideoWireTests: XCTestCase {
    func testParamsAndFrameRoundTrip() throws {
        let sets = [Data([1, 2, 3]), Data([4]), Data(repeating: 9, count: 300)]
        let parsed = try VideoWire.parseParams(VideoWire.params(codec: .h264, sets: sets))
        XCTAssertEqual(parsed.codec, .h264)
        XCTAssertEqual(parsed.sets, sets)
        let frame = try VideoWire.parseFrame(VideoWire.frame(keyframe: true, avcc: Data([7, 7])).reduce(Data(), +))
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
