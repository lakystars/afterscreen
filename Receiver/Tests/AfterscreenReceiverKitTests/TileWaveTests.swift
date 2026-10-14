import Metal
import XCTest
@testable import AfterscreenReceiverKit

final class TileWaveTests: XCTestCase {
    func testOpeningRunsItsDurationThenLeavesThePictureAlone() throws {
        let opening = StreamRenderer.Wave.opening(start: 10, duration: 1)
        XCTAssertEqual(opening.progress(at: 10.25), 0.25)
        XCTAssertEqual(opening.progress(at: 9), 0, "a wave set ahead of its start waits closed")
        XCTAssertNil(opening.progress(at: 11), "done: the picture as sent")
        XCTAssertEqual(StreamRenderer.Wave.hidden.progress(at: 99), 0)
        let closing = StreamRenderer.Wave.closing(start: 10, duration: 1)
        XCTAssertEqual(closing.progress(at: 10.5), 0.5)
        XCTAssertEqual(closing.progress(at: 12), 1, "closed stays closed until the window goes")
        XCTAssertEqual(StreamRenderer.Wave.still.active, 0)
    }

    /// A white 512 × 256 picture (8 × 4 tiles of 64) through `tileFragment` with `wave`; red of each pixel
    private func draw(_ wave: StreamRenderer.Wave, at now: CFTimeInterval) throws -> (Int, Int) -> UInt8 {
        let rgba = try pixels(wave, at: now)
        return { x, y in rgba(x, y, 0) }
    }

    /// White `w` × `h` through `tileFragment`; channel of each pixel
    /// `flash`: per-block stamps, tinted against `flashNow`
    private func pixels(_ wave: StreamRenderer.Wave, at now: CFTimeInterval, w: Int = 512, h: Int = 256,
                        flash: [SIMD4<Float>]? = nil, flashNow: Float = 0) throws -> (Int, Int, Int) -> UInt8 {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: StreamRenderer.shaders, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "screenQuad")
        desc.fragmentFunction = library.makeFunction(name: "tileFragment")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead, .renderTarget]
        let source = try XCTUnwrap(device.makeTexture(descriptor: td))
        source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: w * h * 4), bytesPerRow: w * 4)
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        var p = wave.parameters(at: now, tilePixels: 64, size: CGSize(width: w, height: h))
        // As the renderer does: the grid without a wave too
        p.tilePixels = 64
        p.size = SIMD2(Float(w), Float(h))
        var stamps = flash ?? [SIMD4<Float>(repeating: 0)]
        if flash != nil {
            p.flash = 1
            p.flashNow = flashNow
        }
        enc.setFragmentBytes(&p, length: MemoryLayout<StreamRenderer.Wave.Parameters>.stride, index: 2)
        enc.setFragmentBytes(&stamps, length: stamps.count * MemoryLayout<SIMD4<Float>>.stride, index: 4)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return { x, y, c in pixels[(y * w + x) * 4 + c] }
    }

    func testHiddenIsBlackAndDoneIsThePicture() throws {
        let hidden = try draw(.hidden, at: 0)
        XCTAssertEqual(hidden(224, 96), 0)
        XCTAssertEqual(hidden(32, 32), 0)
        let done = try draw(.opening(start: 0, duration: 1), at: 2)
        XCTAssertEqual(done(224, 96), 255)
        XCTAssertEqual(done(0, 0), 255)
        XCTAssertEqual(done(511, 255), 255)
    }

    func testOpeningStartsAtTheCentre() throws {
        let mid = try draw(.opening(start: 0, duration: 1), at: 0.45)
        XCTAssertGreaterThan(mid(224, 96), 200, "a centre tile is nearly open")
        XCTAssertEqual(mid(32, 32), 0, "a corner tile has not started")
    }

    func testClosingStartsAtTheCorners() throws {
        let mid = try draw(.closing(start: 0, duration: 1), at: 0.55)
        XCTAssertEqual(mid(32, 32), 0, "a corner tile is gone")
        XCTAssertGreaterThan(mid(224, 96), 200, "a centre tile is still up")
        let end = try draw(.closing(start: 0, duration: 1), at: 1)
        XCTAssertEqual(end(224, 96), 0)
    }

    /// 224 high: the last block row is 32 pixels
    /// Its blocks shrink about their own centre
    func testAPartialEdgeBlockShrinksWithinItself() throws {
        let px = try pixels(.opening(start: 0, duration: 1), at: 0.63, h: 224)
        XCTAssertGreaterThan(px(32, 208, 0), 0, "the corner block is opening")
        XCTAssertEqual(px(32, 192, 0), 0, "black above it")
        XCTAssertEqual(px(32, 223, 0), 0, "and below it, at the picture's edge")
    }

    /// Debug tint: red, yellow, blue on exactly their blocks
    func testFlashTintsExactlyTheStampedBlocks() throws {
        var stamps = [SIMD4<Float>](repeating: SIMD4(repeating: -1000), count: 32)
        stamps[1].x = 9.9
        stamps[2].y = 9.9
        stamps[3].z = 9.9
        let px = try pixels(.opening(start: 0, duration: 1), at: 2, flash: stamps, flashNow: 10)
        XCTAssertEqual(px(10, 10, 1), 255, "untouched block")
        XCTAssertEqual(px(63, 10, 1), 255, "last column before the changed block")
        XCTAssertLessThan(px(64, 10, 1), 200, "changed: red, green drops")
        XCTAssertEqual(px(64, 10, 0), 255)
        XCTAssertLessThan(px(150, 10, 2), 200, "sent again: yellow, blue drops")
        XCTAssertLessThan(px(200, 10, 0), 230, "video: blue, red drops")
        let later = try pixels(.opening(start: 0, duration: 1), at: 2, flash: stamps, flashNow: 10.5)
        XCTAssertEqual(later(64, 10, 1), 255, "faded after half a second")
    }

    func testAGrowingTileShowsBlackAroundIt() throws {
        // Early in a tile's opening it is smaller than its cell: the cell's edge is black, its middle lit
        let early = try draw(.opening(start: 0, duration: 1), at: 0.2)
        XCTAssertEqual(early(224 - 31, 96 - 31), 0)
        XCTAssertGreaterThan(early(224, 96), 0)
    }
}

final class PowerSequenceTests: XCTestCase {
    func testASessionWithoutAnEffectLeavesTheNextOneToPowerOn() {
        // No effect, connect and disconnect; then the tile wave, connect again
        var p = PowerSequence()
        XCTAssertTrue(p.powerOn())
        XCTAssertFalse(p.powerOff(effect: .none), "nothing to play")
        XCTAssertTrue(p.powerOn(), "the next window powers on")
    }

    func testOncePerWindowEachWay() {
        var p = PowerSequence()
        XCTAssertFalse(p.powerOff(effect: .tiles), "never on: the window just closes")
        XCTAssertTrue(p.powerOn())
        XCTAssertFalse(p.powerOn())
        XCTAssertTrue(p.powerOff(effect: .tiles))
        XCTAssertFalse(p.powerOff(effect: .crt))
    }
}

final class RelinkHoldTests: XCTestCase {
    func testAHoldThatRunsOutReportsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = StreamWindow(renderer: try XCTUnwrap(StreamRenderer(device: device)), windowed: true)
        // The wake activity and the sleep setting hang on this callback
        let expired = expectation(description: "expired")
        window.hold(for: 0.05) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
    }

    func testAHideBeforeTheTimeoutCancelsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = StreamWindow(renderer: try XCTUnwrap(StreamRenderer(device: device)), windowed: true)
        let expired = expectation(description: "expired")
        expired.isInverted = true
        window.hold(for: 0.05) { expired.fulfill() }
        window.hide()
        wait(for: [expired], timeout: 0.3)
    }
}
