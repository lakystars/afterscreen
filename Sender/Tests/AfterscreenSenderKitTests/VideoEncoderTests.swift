import CoreMedia
import AfterscreenCore
import VideoToolbox
import XCTest
@testable import AfterscreenSenderKit

final class VideoEncoderTests: XCTestCase {
    /// Solid BGRA frame in an IOSurface, as ScreenCaptureKit delivers
    private func frame(width: Int, height: Int, bgra: (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                (p[0], p[1], p[2], p[3]) = (bgra.0, bgra.1, bgra.2, 255)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Decodes one HEVC sample to 4:2:0 (16-bit planes for Main10); returns its size and the centre luma code
    private func decode(params: [Data], sample: Data, tenBit: Bool = false) throws -> (width: Int, height: Int, centreY: Int) {
        var format: CMVideoFormatDescription?
        let pointers = params.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        XCTAssertEqual(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: params.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: params.map(\.count),
                                                                           nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format), noErr)
        let desc = try XCTUnwrap(format)
        var session: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                              : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                    imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session), noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &block)
        let b = try XCTUnwrap(block)
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: sample.count) }
        var cm: CMSampleBuffer?
        var size = sample.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: b, formatDescription: desc, sampleCount: 1, sampleTimingEntryCount: 0,
                                  sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &cm)
        var image: CVImageBuffer?
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: try XCTUnwrap(cm), flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
            image = buffer
        }, noErr)
        let out = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(out, 0), h = CVPixelBufferGetHeightOfPlane(out, 0)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 0)) + (h / 2) * CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        // 10-bit samples sit in the high bits of 16
        let y = tenBit ? Int(base.assumingMemoryBound(to: UInt16.self)[w / 2] >> 6) : Int(base.assumingMemoryBound(to: UInt8.self)[w / 2])
        return (w, h, y)
    }

    /// Receiver's hybrid shader assumes this placement
    /// Plane texel i sits on source pixel i × ratio
    /// True for BGRA sources; ARGB2101010 scales from texel centres
    func testScalingPutsEachTexelOnItsTopLeftSourcePixel() throws {
        let format = Capture.configuration(size: PixelSize(width: 1024, height: 576)).pixelFormat
        for tenBit in [false, true] {
            let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 512, height: 288), bitrate: 20_000_000, tenBit: tenBit)
            let encoder = try XCTUnwrap(VideoEncoder(layer: layer, fps: 60))
            // 0…1 per channel, in the session's capture format
            func scaled(column: Int, rgb: (Double, Double, Double), over: (Double, Double, Double)) throws -> (luma: [Double], cb: [Double]) {
                var pb: CVPixelBuffer?
                let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
                XCTAssertEqual(CVPixelBufferCreate(nil, 1024, 576, format, attrs, &pb), kCVReturnSuccess)
                let source = try XCTUnwrap(pb)
                CVPixelBufferLockBaseAddress(source, [])
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)), stride = CVPixelBufferGetBytesPerRow(source)
                for y in 0..<576 {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<1024 {
                        let c = x == column ? rgb : over
                        if format == kCVPixelFormatType_ARGB2101010LEPacked {
                            let q = { (v: Double) in UInt32((v * 1023).rounded()) }
                            row[x] = 3 << 30 | q(c.0) << 20 | q(c.1) << 10 | q(c.2)
                        } else {
                            let q = { (v: Double) in UInt32((v * 255).rounded()) }
                            row[x] = 255 << 24 | q(c.0) << 16 | q(c.1) << 8 | q(c.2)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(source, [])
                let out = try XCTUnwrap(encoder.scaled(source))
                CVPixelBufferLockBaseAddress(out, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
                // Video range codes to 0…1; 10-bit in high bits
                func plane(_ i: Int, row: Int, _ texels: Range<Int>, step: Int) throws -> [Double] {
                    let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, i)) + row * CVPixelBufferGetBytesPerRowOfPlane(out, i)
                    return texels.map { t in
                        let code = tenBit ? Double(p.assumingMemoryBound(to: UInt16.self)[t * step] >> 6) / 4 : Double(p.assumingMemoryBound(to: UInt8.self)[t * step])
                        return i == 0 ? (code - 16) / 219 : (code - 128) / 224
                    }
                }
                return (try plane(0, row: 100, 148..<154, step: 1), try plane(1, row: 50, 72..<79, step: 2))
            }
            // White column on black: luma texels 148…153
            let even = try scaled(column: 300, rgb: (1, 1, 1), over: (0, 0, 0)).luma
            XCTAssertGreaterThan(even[2], 0.64, "tenBit \(tenBit): pixel 300 belongs to texel 150 \(even)")
            XCTAssertEqual(even[1], even[3], accuracy: 0.01)
            let odd = try scaled(column: 301, rgb: (1, 1, 1), over: (0, 0, 0)).luma
            XCTAssertEqual(odd[2], odd[3], accuracy: 0.01, "tenBit \(tenBit): pixel 301 between texels 150 and 151 \(odd)")
            XCTAssertGreaterThan(odd[2], 0.09)
            // Blue column on grey: chroma texels 72…78, every fourth pixel
            let cb = try scaled(column: 300, rgb: (0, 0, 1), over: (0.5, 0.5, 0.5)).cb
            XCTAssertEqual(cb.firstIndex(of: cb.max()!), 3, "tenBit \(tenBit): pixel 300 belongs to chroma texel 75 \(cb)")
            XCTAssertEqual(cb[2], cb[4], accuracy: 0.01)
        }
    }

    func testPipelinedFramesComeBackInOrderScaledToTheLayerInBT709VideoRange() throws {
        let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 3840, height: 2160), bitrate: 100_000_000)
        let encoder = try XCTUnwrap(VideoEncoder(layer: layer, fps: 60))
        let source = try frame(width: 5120, height: 2880, bgra: (40, 120, 200))
        let lock = NSLock()
        var outputs: [(index: Int, keyframe: Bool, avcc: Data, sets: [Data])] = []
        let done = expectation(description: "outputs")
        // The HEVC encoder's default keys every 30 frames
        done.expectedFulfillmentCount = 40
        for i in 0..<40 {
            XCTAssertTrue(encoder.encode(source, time: 10 + Double(i) / 60, forceKeyframe: i == 0) { output in
                guard case let .frame(keyframe, avcc, sets) = output else { return XCTFail("\(output)") }
                lock.lock()
                outputs.append((i, keyframe, avcc, sets))
                lock.unlock()
                done.fulfill()
            })
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outputs.map(\.index), Array(0..<40), "outputs follow submission order")
        XCTAssertTrue(outputs[0].keyframe)
        XCTAssertFalse(outputs[0].sets.isEmpty)
        XCTAssertFalse(outputs[1...].contains { $0.keyframe }, "no periodic keyframes")

        let picture = try decode(params: outputs[0].sets, sample: outputs[0].avcc)
        XCTAssertEqual(picture.width, 3840)
        XCTAssertEqual(picture.height, 2160)
        // BT.709 video range: 16 + 219 × (0.2126 R + 0.7152 G + 0.0722 B) / 255
        XCTAssertEqual(picture.centreY, 129, accuracy: 4)
    }

    func testEveryFrameKeepsTheCapturedValuesNotJustTheFirst() throws {
        // Pool buffers come back without the BT.709 transfer tag; the sRGB colour space must not make the encoder convert
        for tenBit in [false, true] {
            let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 1920, height: 1080), bitrate: 50_000_000, tenBit: tenBit)
            let encoder = try XCTUnwrap(VideoEncoder(layer: layer, fps: 60))
            var outputs: [VideoEncoder.Output] = []
            for i in 0..<6 {
                let source = try frame(width: 2560, height: 1440, bgra: (40, 120, 200))
                CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), .shouldPropagate)
                let done = expectation(description: "frame \(i)")
                XCTAssertTrue(encoder.encode(source, time: 1 + Double(i) / 60, forceKeyframe: true) { outputs.append($0); done.fulfill() })
                wait(for: [done], timeout: 5)
            }
            guard case let .frame(_, avcc, sets)? = outputs.last else { return XCTFail("\(String(describing: outputs.last))") }
            let y = try decode(params: sets, sample: avcc, tenBit: tenBit).centreY
            XCTAssertEqual(Double(y), tenBit ? 515 : 129, accuracy: tenBit ? 8 : 4, "tenBit \(tenBit): sixth frame")
        }
    }

    func testSRGBTaggedCaptureKeepsItsValuesLikeTheTiles() throws {
        // ScreenCaptureKit tags 8-bit frames sRGB; tiles show the values as they are, so video must too
        for tenBit in [false, true] {
            for tagged in [false, true] {
                let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 1920, height: 1080), bitrate: 50_000_000, tenBit: tenBit)
                let encoder = try XCTUnwrap(VideoEncoder(layer: layer, fps: 60))
                let source = try frame(width: 2560, height: 1440, bgra: (40, 120, 200))
                if tagged {
                    // As ScreenCaptureKit delivers 8-bit sRGB: a CGColorSpace attachment and a colour space on the surface
                    CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), .shouldPropagate)
                    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(source)?.takeUnretainedValue())
                    IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, 15 as CFNumber)
                }
                var output: VideoEncoder.Output?
                let done = expectation(description: "frame")
                XCTAssertTrue(encoder.encode(source, time: 1, forceKeyframe: true) { output = $0; done.fulfill() })
                wait(for: [done], timeout: 5)
                guard case let .frame(_, avcc, sets)? = output else { return XCTFail("\(String(describing: output))") }
                let y = try decode(params: sets, sample: avcc, tenBit: tenBit).centreY
                // BT.709 matrix on the sRGB values, video range: no conversion to the BT.709 curve
                XCTAssertEqual(Double(y), tenBit ? 515 : 129, accuracy: tenBit ? 8 : 4, "tenBit \(tenBit) tagged \(tagged)")
            }
        }
    }

    func testMain10LayerKeepsTenBitsThroughTheEncoder() throws {
        let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 1920, height: 1080), bitrate: 50_000_000, tenBit: true)
        let encoder = try XCTUnwrap(VideoEncoder(layer: layer, fps: 60))
        let source = try frame(width: 2560, height: 1440, bgra: (40, 120, 200))
        var output: VideoEncoder.Output?
        let done = expectation(description: "frame")
        XCTAssertTrue(encoder.encode(source, time: 1, forceKeyframe: true) { output = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        guard case let .frame(_, avcc, sets)? = output else { return XCTFail("\(String(describing: output))") }
        XCTAssertEqual(sets[1][3] & 0x1F, 2, "SPS general_profile_idc: Main10")
        let picture = try decode(params: sets, sample: avcc, tenBit: true)
        // 10-bit video range: 64 + 876 × luma
        XCTAssertEqual(picture.centreY, 515, accuracy: 8)
    }
}
