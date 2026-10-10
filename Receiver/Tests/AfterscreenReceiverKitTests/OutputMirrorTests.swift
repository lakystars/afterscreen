import AudioToolbox
import XCTest
import AfterscreenCore
@testable import AfterscreenReceiverKit

final class OutputMirrorTests: XCTestCase {
    /// Built-in device 1 swaps speakers and headphones as data sources
    /// USB device 2; HDMI device 3 has a fixed volume
    private final class FakeOutput: OutputControl {
        static let speakers = OutputKey(uid: "BuiltIn", source: 1)
        static let headphones = OutputKey(uid: "BuiltIn", source: 2)
        static let usb = OutputKey(uid: "USB", source: nil)
        static let hdmi = OutputKey(uid: "HDMI", source: nil)

        var levels: [OutputKey: OutputLevel] = [speakers: OutputLevel(volume: 0.5, muted: false),
                                                headphones: OutputLevel(volume: 1, muted: false),
                                                usb: OutputLevel(volume: 0.2, muted: true)]
        var headphonesIn = false
        var defaultOutput = speakers
        var writes: [OutputKey] = []

        private func active(_ key: OutputKey) -> OutputKey {
            key.uid == "BuiltIn" ? (headphonesIn ? FakeOutput.headphones : FakeOutput.speakers) : key
        }
        private func id(_ key: OutputKey) -> AudioObjectID { ["BuiltIn": 1, "USB": 2, "HDMI": 3][key.uid]! }
        private func key(_ device: AudioObjectID) -> OutputKey { active([1: FakeOutput.speakers, 2: FakeOutput.usb, 3: FakeOutput.hdmi][device]!) }

        var current: (id: AudioObjectID, key: OutputKey)? {
            let k = active(defaultOutput)
            return (id(k), k)
        }
        func device(for key: OutputKey) -> AudioObjectID? { active(key) == key ? id(key) : nil }
        func level(of device: AudioObjectID) -> OutputLevel? { levels[key(device)] }
        func set(_ level: OutputLevel, on device: AudioObjectID) {
            levels[key(device)] = level
            writes.append(key(device))
        }
    }

    private let output = FakeOutput()
    private lazy var mirror = OutputMirror(control: output, watches: false)
    private let quiet = OutputLevel(volume: 0.3, muted: false)
    private let muted = OutputLevel(volume: 0.25, muted: true)
    private let speakersOwn = OutputLevel(volume: 0.5, muted: false)

    func testTheIMacTakesEachSenderLevelThenGetsItsOwnBack() {
        mirror.follow(quiet)
        XCTAssertEqual(output.levels[FakeOutput.speakers], quiet)
        mirror.follow(muted)
        XCTAssertEqual(output.levels[FakeOutput.speakers], muted)
        mirror.restore()
        XCTAssertEqual(output.levels[FakeOutput.speakers], speakersOwn, "the level from before the first follow")
    }

    func testANilLevelRestoresOnce() {
        mirror.follow(quiet)
        mirror.follow(nil)
        XCTAssertEqual(output.levels[FakeOutput.speakers], speakersOwn)
        mirror.restore()
        XCTAssertEqual(output.writes, [FakeOutput.speakers, FakeOutput.speakers])
    }

    func testANewDefaultDeviceFollowsAndEveryTouchedDeviceIsRestored() {
        mirror.follow(quiet)
        output.defaultOutput = FakeOutput.usb
        mirror.outputChanged()
        XCTAssertEqual(output.levels[FakeOutput.usb], quiet)
        mirror.restore()
        XCTAssertEqual(output.levels[FakeOutput.speakers], speakersOwn)
        XCTAssertEqual(output.levels[FakeOutput.usb], OutputLevel(volume: 0.2, muted: true))
    }

    func testHeadphonesFollowAndTheSpeakersAreRestoredOnceUnplugged() {
        mirror.follow(quiet)
        output.headphonesIn = true
        mirror.outputChanged()
        XCTAssertEqual(output.levels[FakeOutput.headphones], quiet, "the jack swaps the source, not the device")
        mirror.restore()
        XCTAssertEqual(output.levels[FakeOutput.headphones], OutputLevel(volume: 1, muted: false))
        XCTAssertEqual(output.levels[FakeOutput.speakers], quiet, "inactive source: its volume cannot be set yet")
        output.headphonesIn = false
        mirror.outputChanged()
        XCTAssertEqual(output.levels[FakeOutput.speakers], speakersOwn)
    }

    func testAWaitingOutputFollowedAgainKeepsItsOriginalLevel() {
        mirror.follow(quiet)
        output.headphonesIn = true
        mirror.outputChanged()
        mirror.restore()
        output.headphonesIn = false
        // Next session starts before the unplug is noticed
        mirror.follow(muted)
        mirror.restore()
        XCTAssertEqual(output.levels[FakeOutput.speakers], speakersOwn, "not the first session's leftover")
    }

    func testAFixedVolumeDeviceIsLeftAlone() {
        output.defaultOutput = FakeOutput.hdmi
        mirror.follow(quiet)
        mirror.restore()
        XCTAssertEqual(output.writes, [])
    }

    func testRestoreWithoutAFollowTouchesNothing() {
        mirror.restore()
        XCTAssertEqual(output.writes, [])
    }
}
