import CoreAudio
import XCTest
@testable import AfterscreenCore

final class HeadphonesTests: XCTestCase {
    func testPersonalOutputsKeepTheSound() {
        XCTAssertTrue(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBluetooth, source: nil))
        XCTAssertTrue(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBluetoothLE, source: nil))
        // Built-in jack: same device, headphone source
        XCTAssertTrue(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBuiltIn, source: 0x6864_706E))
        XCTAssertFalse(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBuiltIn, source: 0x6973_706B))
        XCTAssertTrue(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBuiltIn, source: nil, uid: "BuiltInHeadphoneOutputDevice"))
        XCTAssertFalse(SystemOutput.headphones(transport: kAudioDeviceTransportTypeBuiltIn, source: nil, uid: "BuiltInSpeakerDevice"))
        XCTAssertFalse(SystemOutput.headphones(transport: kAudioDeviceTransportTypeHDMI, source: nil))
        XCTAssertFalse(SystemOutput.headphones(transport: kAudioDeviceTransportTypeAirPlay, source: nil))
    }
}
