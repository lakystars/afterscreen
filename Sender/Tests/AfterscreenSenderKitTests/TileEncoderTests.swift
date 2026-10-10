import AppKit
import CoreText
import Metal
import AfterscreenCore
import XCTest
@testable import AfterscreenSenderKit

final class TileEncoderTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal unavailable")
    }

    // MARK: - Helpers

    /// RGBA pixels → BGRA texture
    private func texture(width: Int, height: Int, rgba: [UInt8]) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        var bgra = rgba
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bgra, bytesPerRow: width * 4)
        return tex
    }

    /// CPU-decodes the encoder's tile-major reference back into RGBA
    private func decodeCPU(_ encoder: TileEncoder, geometry g: TileGeometry) -> [UInt8] {
        let bytes = encoder.reference
        var out = [UInt8](repeating: 0, count: g.width * g.height * 4)
        for by in 0..<g.blocksY {
            for bx in 0..<g.blocksX {
                let offset = TileEncoder.blockOffset(bx: bx, by: by, geometry: g)
                let rgba = BC7.decodeBlock(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + 16]))
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bx * 4 + px, y = by * 4 + py
                        guard x < g.width, y < g.height else { continue }
                        for c in 0..<4 { out[(y * g.width + x) * 4 + c] = rgba[(py * 4 + px) * 4 + c] }
                    }
                }
            }
        }
        return out
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0, n = 0.0
        for i in 0..<a.count where i % 4 != 3 {
            let d = Double(a[i]) - Double(b[i])
            sum += d * d
            n += 1
        }
        let mse = sum / n
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    private func drawText(width: Int, height: Int, fg: CGColor, bg: CGColor) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        for row in 0..<4 {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Afterscreen 5K60 — The quick brown fox \(row)", attributes: attrs))
            ctx.textPosition = CGPoint(x: 6, y: 10 + row * 30)
            CTLineDraw(line, ctx)
        }
        return pixels
    }

    private func encodeOnce(_ rgba: [UInt8], width: Int, height: Int) throws -> (TileEncoder, TileGeometry) {
        let g = TileGeometry(width: width, height: height)
        let encoder = try TileEncoder(device: device, geometry: g)
        _ = encoder.encode(texture: texture(width: width, height: height, rgba: rgba), forceAll: true, dirty: nil)
        return (encoder, g)
    }

    // MARK: - Quality

    func testFlatColorIsNearExact() throws {
        let rgba: [UInt8] = (0..<64 * 64).flatMap { _ -> [UInt8] in [37, 142, 201, 255] }
        let (encoder, g) = try encodeOnce(rgba, width: 64, height: 64)
        let out = decodeCPU(encoder, geometry: g)
        for i in stride(from: 0, to: out.count, by: 4) {
            for c in 0..<3 {
                let diff = abs(Int(out[i + c]) - Int(rgba[i + c]))
                XCTAssertLessThanOrEqual(diff, 1)
            }
        }
    }

    func testGradientPSNR() throws {
        let w = 256, h = 64
        let rgba = (0..<w * h).flatMap { i -> [UInt8] in
            let x = i % w
            return [UInt8(x), UInt8(255 - x), 128, 255]
        }
        let (encoder, g) = try encodeOnce(rgba, width: w, height: h)
        XCTAssertGreaterThanOrEqual(psnr(decodeCPU(encoder, geometry: g), rgba), 38)
    }

    func testBlackOnWhiteTextPSNR() throws {
        let w = 512, h = 128
        let rgba = drawText(width: w, height: h, fg: CGColor(gray: 0, alpha: 1), bg: CGColor(gray: 1, alpha: 1))
        let (encoder, g) = try encodeOnce(rgba, width: w, height: h)
        XCTAssertGreaterThanOrEqual(psnr(decodeCPU(encoder, geometry: g), rgba), 38)
    }

    func testColoredTextPSNR() throws {
        let w = 512, h = 128
        let rgba = drawText(width: w, height: h, fg: CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1),
                            bg: CGColor(red: 1, green: 0.95, blue: 0.6, alpha: 1))
        let (encoder, g) = try encodeOnce(rgba, width: w, height: h)
        XCTAssertGreaterThanOrEqual(psnr(decodeCPU(encoder, geometry: g), rgba), 32)
    }

    func testTenBitSourceIsDitheredNotRoundedToOneLevel() throws {
        // 10-bit 410 is 102.20 in 8-bit steps: rounding paints 102 everywhere, a dark band
        let w = 64, h = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let word: UInt32 = 3 << 30 | 410 << 20 | 410 << 10 | 410
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: [UInt32](repeating: word, count: w * h), bytesPerRow: w * 4)
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g)
        _ = encoder.encode(texture: tex, forceAll: true, dirty: nil)
        let out = decodeCPU(encoder, geometry: g)
        let reds = stride(from: 0, to: out.count, by: 4).map { Int(out[$0]) }
        XCTAssertEqual(Set(reds), [102, 103])
        XCTAssertEqual(Double(reds.reduce(0, +)) / Double(reds.count), 410.0 / 1023 * 255, accuracy: 0.05)
    }

    func testPartialEdgeTilesDecodeInsideStream() throws {
        let w = 96, h = 72 // 2×2 tiles, both partial
        let rgba = (0..<w * h).flatMap { i -> [UInt8] in [UInt8(i % w * 2), UInt8(i / w * 3), 90, 255] }
        let (encoder, g) = try encodeOnce(rgba, width: w, height: h)
        XCTAssertEqual(g.tileCount, 4)
        XCTAssertGreaterThanOrEqual(psnr(decodeCPU(encoder, geometry: g), rgba), 38)
    }

    // MARK: - Hardware decode matches the reference decoder

    func testHardwareSamplingMatchesCPUDecoder() throws {
        let w = 128, h = 64
        let rgba = drawText(width: w, height: h, fg: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1),
                            bg: CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        let (encoder, g) = try encodeOnce(rgba, width: w, height: h)
        let cpu = decodeCPU(encoder, geometry: g)
        let gpu = try HardwareBC7Probe(device: device).decode(encoder, geometry: g)
        XCTAssertEqual(gpu.count, cpu.count)
        var maxDiff = 0
        for i in 0..<cpu.count where i % 4 != 3 { maxDiff = max(maxDiff, abs(Int(cpu[i]) - Int(gpu[i]))) }
        XCTAssertLessThanOrEqual(maxDiff, 1)
    }

    // MARK: - Dirty tracking and upload layout

    func testDirtyRunsFollowTheLastEncodedFrame() throws {
        let w = 128, h = 128 // 2×2 tiles
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g)
        let base = (0..<w * h).flatMap { i -> [UInt8] in [UInt8(i % 251), 60, 90, 255] }
        let first = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: base), forceAll: false, dirty: nil, now: 10)?.runs)
        XCTAssertEqual(first, [TileRun(row: 0, first: 0, count: 2), TileRun(row: 1, first: 0, count: 2)])
        XCTAssertNil(encoder.encode(texture: texture(width: w, height: h, rgba: base), forceAll: false, dirty: nil, now: 11))

        var changed = base
        let px = (70 * w + 100) * 4 // tile (1, 1)
        changed[px] = 255; changed[px + 1] = 0; changed[px + 2] = 0
        let one = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: changed), forceAll: false, dirty: nil, now: 12)?.runs)
        XCTAssertEqual(one, [TileRun(row: 1, first: 1, count: 1)])
        let back = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: base), forceAll: false, dirty: nil, now: 13)?.runs)
        XCTAssertEqual(back, [TileRun(row: 1, first: 1, count: 1)])
        let forced = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: base), forceAll: true, dirty: nil, now: 14)?.runs)
        XCTAssertEqual(forced.reduce(0) { $0 + $1.count }, 4)
    }

    func testUploadHoldsRunBlocksRowMajorIncludingPartialEdges() throws {
        let w = 200, h = 136 // 4×3 tiles; last column 8 px wide, last row 8 px tall
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g)
        let rgba = (0..<w * h).flatMap { i -> [UInt8] in [UInt8(i % 199), UInt8(i % 97), UInt8((i / w) % 61), 255] }
        let frame = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: rgba), forceAll: true, dirty: nil))
        XCTAssertEqual(frame.runs, (0..<3).map { TileRun(row: $0, first: 0, count: 4) })
        XCTAssertEqual(frame.data.count, g.blocksX * g.blocksY * 16)
        let ref = encoder.reference
        var offset = 0, mismatches = 0
        frame.data.withUnsafeBytes { data in
            for run in frame.runs {
                let b = run.blocks(in: g)
                for y in 0..<b.h {
                    for x in 0..<b.w {
                        let src = TileEncoder.blockOffset(bx: run.first * 16 + x, by: run.row * 16 + y, geometry: g)
                        if memcmp(data.baseAddress! + offset + (y * b.w + x) * 16, ref.baseAddress! + src, 16) != 0 { mismatches += 1 }
                    }
                }
                offset += run.bytes(in: g)
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    func testTilesUnderDirtyRectsClipToTheStream() {
        let g = TileGeometry(width: 200, height: 136) // 4×3 tiles
        var flags = [Bool](repeating: false, count: g.tileCount)
        TileEncoder.markTiles(under: [CGRect(x: 60, y: 10, width: 10, height: 60), CGRect(x: 190, y: 130, width: 500, height: 500),
                                      CGRect(x: -50, y: -50, width: 10, height: 10)], geometry: g, into: &flags)
        XCTAssertEqual(flags.indices.filter { flags[$0] }, [0, 1, 4, 5, 10, 11])
    }

    func testOnlyTilesUnderDirtyRectsAreEncodedAndTheRefreshCatchesTheRest() throws {
        let w = 256, h = 64 // 4×1 tiles, one refresh tile per frame
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g)
        let base = (0..<w * h).flatMap { i -> [UInt8] in [UInt8(i % 251), 60, 90, 255] }
        _ = encoder.encode(texture: texture(width: w, height: h, rgba: base), forceAll: true, dirty: nil, now: 0)
        var changed = base
        for x in [10, 200] { changed[(20 * w + x) * 4] &+= 99 } // tiles 0 and 3
        let tex = texture(width: w, height: h, rgba: changed)
        let first = encoder.encode(texture: tex, forceAll: false, dirty: [CGRect(x: 0, y: 0, width: 64, height: 64)], now: 10)?.runs
        XCTAssertEqual(first, [TileRun(row: 0, first: 0, count: 1)])
        var later: [TileRun] = []
        for i in 0..<g.tileCount {
            later += encoder.encode(texture: tex, forceAll: false, dirty: [], now: 20 + Double(i))?.runs ?? []
        }
        XCTAssertEqual(later, [TileRun(row: 0, first: 3, count: 1)])
    }

    func testUploadBufferReturnsWhenTheFrameIsReleased() throws {
        let w = 64, h = 64
        let encoder = try TileEncoder(device: device, geometry: TileGeometry(width: w, height: h), uploadBuffers: 1)
        let a = (0..<w * h).flatMap { _ -> [UInt8] in [10, 20, 30, 255] }
        let b = (0..<w * h).flatMap { _ -> [UInt8] in [200, 20, 30, 255] }
        var base: UnsafeRawPointer?
        do {
            let first = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: a), forceAll: true, dirty: nil))
            base = first.data.withUnsafeBytes { $0.baseAddress }
        }
        let second = try XCTUnwrap(encoder.encode(texture: texture(width: w, height: h, rgba: b), forceAll: false, dirty: nil))
        XCTAssertEqual(second.data.withUnsafeBytes { $0.baseAddress }, base)
    }
}

final class MotionTests: XCTestCase {
    func texture(_ device: MTLDevice, _ pixels: [UInt32], _ w: Int, _ h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        let t = device.makeTexture(descriptor: desc)!
        pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return t
    }

    func testMotionWithinTheBC7BudgetStaysSharpAndPastItFallsBackToBC1() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 128, h = 64
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g, uploadBuffers: 8)
        encoder.bc7MotionLimit = 2
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 0), w, h), forceAll: true, dirty: nil, now: 0)
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 1), w, h), forceAll: false, dirty: nil, now: 1)
        let moving = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 2), w, h), forceAll: false, dirty: nil, now: 1.016))
        XCTAssertEqual(moving.runs, [TileRun(row: 0, first: 0, count: 2)])
        XCTAssertEqual(moving.data.count, g.blocksX * g.blocksY * BC7.blockBytes)
        XCTAssertEqual(encoder.lossyTiles, 0)
        XCTAssertNil(encoder.nextRefinement(now: 1.016), "nothing left to settle")

        encoder.bc7MotionLimit = 1
        let over = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 3), w, h), forceAll: false, dirty: nil, now: 1.032))
        XCTAssertEqual(over.runs, [TileRun(row: 0, first: 0, count: 2, format: .bc1)])
        XCTAssertEqual(encoder.lossyTiles, 2)
    }

    /// Video-like colour field with a moving phase, BGRA (a few levels per pixel per channel)
    func scene(_ w: Int, _ h: Int, phase: Double) -> [UInt32] {
        (0..<(w * h)).map { i -> UInt32 in
            let x = Double(i % w), y = Double(i / w)
            let r = UInt32(127 + 120 * sin(x / 24 + phase)), g = UInt32(127 + 120 * cos(y / 20 - phase)), b = UInt32(127 + 100 * sin((x + y) / 30))
            return 0xFF00_0000 | r << 16 | g << 8 | b
        }
    }

    /// Decodes our BC1 semantics: c0, c1, then 21/64 and 43/64 of the way from c0 to c1
    private func decodeBC1(_ block: UnsafeRawBufferPointer) -> [(Int, Int, Int)] {
        let ends = block.load(as: UInt32.self), bits = block.load(fromByteOffset: 4, as: UInt32.self)
        func expand(_ v: UInt32) -> (Int, Int, Int) {
            let r = Int(v >> 11 & 31), g = Int(v >> 5 & 63), b = Int(v & 31)
            return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
        }
        let a = expand(ends & 0xFFFF), b = expand(ends >> 16)
        func mix(_ w: Int) -> (Int, Int, Int) {
            (((64 - w) * a.0 + w * b.0 + 32) >> 6, ((64 - w) * a.1 + w * b.1 + 32) >> 6, ((64 - w) * a.2 + w * b.2 + 32) >> 6)
        }
        let palette = [a, b, mix(21), mix(43)]
        return (0..<16).map { palette[Int(bits >> (2 * UInt32($0)) & 3)] }
    }

    func testTilesInMotionGoOutAsBC1AndSettleToTheirBC7Reference() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 128, h = 64
        let g = TileGeometry(width: w, height: h)
        // This test keeps several frames alive at once
        let encoder = try TileEncoder(device: device, geometry: g, uploadBuffers: 8)
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 0), w, h), forceAll: true, dirty: nil, now: 0)
        let first = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 1), w, h), forceAll: false, dirty: nil, now: 1))
        XCTAssertEqual(first.runs, [TileRun(row: 0, first: 0, count: 2)], "a change after a pause is sharp")
        let moving = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 2), w, h), forceAll: false, dirty: nil, now: 1.016))
        XCTAssertEqual(moving.runs, [TileRun(row: 0, first: 0, count: 2, format: .bc1)])
        XCTAssertEqual(moving.data.count, g.blocksX * g.blocksY * 8)
        XCTAssertEqual(encoder.nextRefinement(now: 1.016) ?? 0, TileEncoder.settleDelay, accuracy: 1e-9)
        XCTAssertNil(encoder.refine(now: 1.05))

        // BC1 stays close to the source while it moves
        let source = scene(w, h, phase: 2)
        var se = 0.0
        moving.data.withUnsafeBytes { raw in
            for by in 0..<g.blocksY {
                for bx in 0..<g.blocksX {
                    let px = decodeBC1(UnsafeRawBufferPointer(rebasing: raw[((by * g.blocksX + bx) * 8)..<((by * g.blocksX + bx) * 8 + 8)]))
                    for i in 0..<16 {
                        let s = source[(by * 4 + i / 4) * w + bx * 4 + i % 4]
                        let d = [Int(s >> 16 & 255) - px[i].0, Int(s >> 8 & 255) - px[i].1, Int(s & 255) - px[i].2]
                        se += Double(d.reduce(0) { $0 + $1 * $1 })
                    }
                }
            }
        }
        let psnr = 10 * log10(255.0 * 255.0 / (se / Double(w * h * 3)))
        XCTAssertGreaterThan(psnr, 36, "BC1 PSNR \(psnr)")

        let settled = try XCTUnwrap(encoder.refine(now: 1.2))
        XCTAssertEqual(settled.runs, [TileRun(row: 0, first: 0, count: 2)])
        let ref = encoder.reference
        var mismatches = 0
        settled.data.withUnsafeBytes { data in
            for by in 0..<g.blocksY {
                for bx in 0..<g.blocksX where memcmp(data.baseAddress! + (by * g.blocksX + bx) * 16,
                                                     ref.baseAddress! + TileEncoder.blockOffset(bx: bx, by: by, geometry: g), 16) != 0 {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertNil(encoder.nextRefinement(now: 1.2))

        // A link-bound stream (frames further apart than the motion window) still sends motion as BC1
        let slow = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 3), w, h), forceAll: false, dirty: nil,
                                                now: 5, congested: true))
        XCTAssertEqual(slow.runs, [TileRun(row: 0, first: 0, count: 2)], "the first change after a pause stays sharp")
        let slower = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 4), w, h), forceAll: false, dirty: nil,
                                                  now: 5.2, congested: true))
        XCTAssertEqual(slower.runs, [TileRun(row: 0, first: 0, count: 2, format: .bc1)])

        // A link so slow that frames are seconds apart: consecutive changes still mean motion
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 5), w, h), forceAll: false, dirty: nil, now: 20, congested: true)
        let crawling = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 6), w, h), forceAll: false, dirty: nil,
                                                    now: 21.2, congested: true))
        XCTAssertEqual(crawling.runs, [TileRun(row: 0, first: 0, count: 2, format: .bc1)])
        // Without congestion, a change a second later is an edit, not motion
        _ = encoder.refine(now: 30)
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 7), w, h), forceAll: false, dirty: nil, now: 40)
        let edit = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 8), w, h), forceAll: false, dirty: nil, now: 41.2))
        XCTAssertEqual(edit.runs, [TileRun(row: 0, first: 0, count: 2)])
    }
}

extension MotionTests {
    private func blocksMatch(_ frame: EncodedFrame, _ reference: UnsafeRawBufferPointer, _ g: TileGeometry) -> Bool {
        frame.data.withUnsafeBytes { data in
            (0..<g.blocksY).allSatisfy { by in
                (0..<g.blocksX).allSatisfy { bx in
                    memcmp(data.baseAddress! + (by * g.blocksX + bx) * 16,
                           reference.baseAddress! + TileEncoder.blockOffset(bx: bx, by: by, geometry: g), 16) == 0
                }
            }
        }
    }

    func testMovingTilesSwitchToTheVideoLayerAndSettleToTheLatestBC7() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 128, h = 64
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g, uploadBuffers: 6)
        encoder.motion = .video
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 0), w, h), forceAll: true, dirty: nil, now: 0)
        let first = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 1), w, h), forceAll: false, dirty: nil, now: 1))
        XCTAssertEqual(first.runs, [TileRun(row: 0, first: 0, count: 2)], "a change after a pause is sharp")
        XCTAssertEqual(encoder.lossyTiles, 0)

        let entering = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 2), w, h), forceAll: false, dirty: nil, now: 1.016))
        XCTAssertEqual(entering.runs, [TileRun(row: 0, first: 0, count: 2, format: .video)])
        XCTAssertEqual(entering.data.count, 0)
        XCTAssertEqual(encoder.lossyTiles, 2)

        XCTAssertNil(encoder.encode(texture: texture(device, scene(w, h, phase: 3), w, h), forceAll: false, dirty: nil, now: 1.032),
                     "tiles already on the video layer send nothing")
        XCTAssertNil(encoder.encode(texture: texture(device, scene(w, h, phase: 4), w, h), forceAll: false, dirty: nil, now: 1.112),
                     "a slower change before the tile settles keeps it on the video layer")
        XCTAssertEqual(encoder.lossyTiles, 2)

        let settled = try XCTUnwrap(encoder.refine(now: 1.3))
        XCTAssertEqual(settled.runs, [TileRun(row: 0, first: 0, count: 2)])
        XCTAssertEqual(encoder.lossyTiles, 0)
        let fresh = try TileEncoder(device: device, geometry: g)
        _ = fresh.encode(texture: texture(device, scene(w, h, phase: 4), w, h), forceAll: true, dirty: nil, now: 0)
        XCTAssertTrue(blocksMatch(settled, fresh.reference, g), "the settled tiles carry the last moving picture")
    }

    func testAfterASlowFullFrameTheNextCongestedChangeIsMotion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 128, h = 64
        let encoder = try TileEncoder(device: device, geometry: TileGeometry(width: w, height: h))
        _ = encoder.encode(texture: texture(device, scene(w, h, phase: 0), w, h), forceAll: true, dirty: nil, now: 0)
        // The full frame took 1.3 s on the link while the source kept moving
        let next = try XCTUnwrap(encoder.encode(texture: texture(device, scene(w, h, phase: 1), w, h), forceAll: false, dirty: nil,
                                                now: 1.3, congested: true))
        XCTAssertEqual(next.runs, [TileRun(row: 0, first: 0, count: 2, format: .bc1)])
    }

    func testSettlingIsCappedPerFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 128, h = 64
        let encoder = try TileEncoder(device: device, geometry: TileGeometry(width: w, height: h), uploadBuffers: 6)
        encoder.motion = .video
        encoder.settleLimit = 1
        for (i, now) in [0, 1, 1.016].enumerated() {
            _ = encoder.encode(texture: texture(device, scene(w, h, phase: Double(i)), w, h), forceAll: i == 0, dirty: nil, now: now)
        }
        XCTAssertEqual(encoder.lossyTiles, 2)
        XCTAssertEqual(try XCTUnwrap(encoder.refine(now: 1.2)).runs, [TileRun(row: 0, first: 0, count: 1)])
        XCTAssertEqual(encoder.lossyTiles, 1)
        XCTAssertEqual(encoder.nextRefinement(now: 1.2), 0)
        XCTAssertEqual(try XCTUnwrap(encoder.refine(now: 1.21)).runs, [TileRun(row: 0, first: 1, count: 1)])
        XCTAssertNil(encoder.nextRefinement(now: 1.21))
    }
}

final class TilePackerTests: XCTestCase {
    private func frame(compressible: Bool) throws -> (EncodedFrame, TileGeometry, TileEncoder) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let w = 1024, h = 512
        let g = TileGeometry(width: w, height: h)
        let encoder = try TileEncoder(device: device, geometry: g)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var state: UInt32 = 7
        let pixels = (0..<w * h).map { i -> UInt32 in
            if compressible { return i % w < w / 2 ? 0xFFFF_FFFF : 0xFF20_4080 }
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return 0xFF00_0000 | state & 0xFF_FFFF
        }
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return (try XCTUnwrap(encoder.encode(texture: tex, forceAll: true, dirty: nil)), g, encoder)
    }

    private func payload(_ parts: [Data]) -> Data { parts.reduce(Data(), +) }

    func testStoredChunksAliasTheUploadBuffer() throws {
        let (f, g, _) = try frame(compressible: false)
        let packed = TilePacker().pack(f, geometry: g, compression: .none)
        XCTAssertEqual(packed.parts[1].withUnsafeBytes { $0.baseAddress }, f.data.withUnsafeBytes { $0.baseAddress })
        let parsed = try TileFrame(payload: payload(packed.parts), expecting: g)
        XCTAssertEqual(parsed.runs, f.runs)
        XCTAssertTrue(parsed.chunks.allSatisfy { !$0.compressed })
        XCTAssertEqual(try parsed.decodeAll(), f.data)
        XCTAssertEqual(packed.wireBytes, payload(packed.parts).count)
    }

    func testCompressedPackRoundTripsInParallelChunks() throws {
        let (f, g, _) = try frame(compressible: true)
        let packed = TilePacker().pack(f, geometry: g, compression: .all)
        let parsed = try TileFrame(payload: payload(packed.parts), expecting: g)
        XCTAssertGreaterThan(parsed.chunks.count, 1)
        XCTAssertLessThanOrEqual(parsed.chunks.count, TilePacker.maxChunks)
        XCTAssertTrue(parsed.chunks.allSatisfy(\.compressed))
        XCTAssertLessThan(packed.wireBytes, f.data.count / 4)
        XCTAssertEqual(try parsed.decodeAll(), f.data)
        XCTAssertEqual(packed.lz4In, f.data.count)
        XCTAssertEqual(packed.lz4Out, packed.wireBytes - packed.parts[0].count)
    }

    func testProbeCompressesOnlyTheFirstChunk() throws {
        let (f, g, _) = try frame(compressible: true)
        let packed = TilePacker().pack(f, geometry: g, compression: .firstChunk)
        let parsed = try TileFrame(payload: payload(packed.parts), expecting: g)
        XCTAssertEqual(parsed.chunks.map(\.compressed), [true] + Array(repeating: false, count: parsed.chunks.count - 1))
        XCTAssertEqual(packed.lz4In, parsed.chunks[0].rawSize)
        XCTAssertEqual(try parsed.decodeAll(), f.data)
    }
}

final class TileEncoderPerformanceTests: XCTestCase {
    /// 5K frame must encode and diff well inside a 60 Hz frame on the GPU
    func test5KEncodeFitsFrameBudget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = TileGeometry(width: 5120, height: 2880)
        let encoder = try TileEncoder(device: device, geometry: g)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: g.width, height: g.height, mipmapped: false)
        desc.usage = .shaderRead
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var noise = [UInt8](repeating: 0, count: g.width * 4)
        for y in 0..<g.height {
            for i in 0..<noise.count { noise[i] = UInt8(truncatingIfNeeded: (i * 7 + y * 13) ^ (i >> 3)) }
            tex.replace(region: MTLRegionMake2D(0, y, g.width, 1), mipmapLevel: 0, withBytes: noise, bytesPerRow: noise.count)
        }
        _ = encoder.encode(texture: tex, forceAll: true, dirty: nil)
        var best = Double.infinity
        for _ in 0..<5 {
            _ = encoder.encode(texture: tex, forceAll: true, dirty: nil)
            best = min(best, encoder.lastGPUSeconds)
        }
        print("5K encode GPU ms:", best * 1000)
        XCTAssertLessThan(best, 0.008)
    }
}
