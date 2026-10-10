import QuartzCore
import XCTest
@testable import AfterscreenReceiverKit

final class CRTEffectTests: XCTestCase {
    private let size = CGSize(width: 2560, height: 1440)

    /// Linear between keyframes; enough to check what shows when
    private func value(_ track: CRTEffect.Track, at t: Double) -> CGFloat {
        let k = track.keys
        guard let next = k.firstIndex(where: { $0.time >= t }) else { return k[k.count - 1].value }
        guard next > 0 else { return k[0].value }
        let a = k[next - 1], b = k[next]
        let f = b.time > a.time ? CGFloat((t - a.time) / (b.time - a.time)) : 1
        return a.value + (b.value - a.value) * f
    }

    private func track(_ tracks: [CRTEffect.Track], _ keyPath: String) -> CRTEffect.Track? {
        tracks.first { $0.keyPath == keyPath }
    }

    private func checkWellFormed(_ t: CRTEffect.Timeline, file: StaticString = #filePath, line: UInt = #line) {
        for tr in t.picture + t.wash + t.beam + t.halo {
            XCTAssertEqual(tr.keys.first?.time, 0, tr.keyPath, file: file, line: line)
            XCTAssertLessThanOrEqual(tr.keys.last?.time ?? 2, 1, tr.keyPath, file: file, line: line)
            XCTAssertEqual(tr.keys.map(\.time), tr.keys.map(\.time).sorted(), tr.keyPath, file: file, line: line)
        }
    }

    func testPowerOffCollapsesToALineThenADotThatFades() throws {
        let off = CRTEffect.off(size: size)
        checkWellFormed(off)
        let scaleY = try XCTUnwrap(track(off.picture, "transform.scale.y"))
        let width = try XCTUnwrap(track(off.beam, "bounds.size.width"))
        let beam = try XCTUnwrap(track(off.beam, "opacity"))
        XCTAssertEqual(value(scaleY, at: 1) * size.height, CRTEffect.line, accuracy: 0.01, "the picture ends as a line")
        XCTAssertEqual(value(try XCTUnwrap(track(off.picture, "opacity")), at: 1), 0)
        XCTAssertEqual(value(try XCTUnwrap(track(off.wash, "opacity")), at: off.collapsed), 1, "a collapsing tube burns white")
        XCTAssertEqual(value(beam, at: off.collapsed), 1, "the beam takes over as the picture becomes a line")
        XCTAssertEqual(value(width, at: off.collapsed), size.width)
        XCTAssertEqual(value(width, at: off.dot), CRTEffect.dot, "then shrinks to a dot")
        XCTAssertEqual(value(beam, at: off.dot), 1)
        XCTAssertEqual(value(beam, at: 1), 0, "the dot fades last")
        XCTAssertGreaterThan(1 - off.dot, 0.4, "the afterglow lingers")
    }

    func testPowerOnGrowsFromADotToTheFullPicture() throws {
        let on = CRTEffect.on(size: size)
        checkWellFormed(on)
        let width = try XCTUnwrap(track(on.beam, "bounds.size.width"))
        let picture = try XCTUnwrap(track(on.picture, "opacity"))
        let scaleY = try XCTUnwrap(track(on.picture, "transform.scale.y"))
        XCTAssertEqual(value(width, at: 0), CRTEffect.dot, "a dot first")
        XCTAssertEqual(value(picture, at: 0), 0)
        XCTAssertEqual(value(width, at: on.line), size.width, "then a full-width line")
        XCTAssertEqual(value(scaleY, at: 1), 1)
        XCTAssertEqual(value(picture, at: 1), 1)
        XCTAssertEqual(on.wash.flatMap(\.keys).map(\.value).max(), 0, "the picture opens in its own colours, no white flash")
        XCTAssertEqual(value(try XCTUnwrap(track(on.beam, "opacity")), at: 1), 0)
    }

    func testAnimationsCarryTheTimelineDuration() throws {
        let off = CRTEffect.off(size: size)
        let group = CRTEffect.animation(off.picture, duration: off.duration)
        XCTAssertEqual(group.duration, off.duration)
        let keyframes = try XCTUnwrap(group.animations as? [CAKeyframeAnimation])
        XCTAssertEqual(keyframes.map(\.keyPath), off.picture.map(\.keyPath))
        XCTAssertEqual(keyframes.first?.timingFunctions?.count, (keyframes.first?.values?.count ?? 0) - 1)
    }
}
