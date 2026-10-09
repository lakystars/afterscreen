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

    /// Decodes one HEVC sample to NV12; returns its size and the luma at the centre
    private func decode(params: [Data], sample: Data) throws -> (width: Int, height: Int, centreY: Int) {
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
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
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
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt8.self)
        return (w, h, Int(luma[(h / 2) * CVPixelBufferGetBytesPerRowOfPlane(out, 0) + w / 2]))
    }

    func testScalesTheCaptureToTheLayerSynchronouslyInBT709VideoRange() throws {
        let layer = VideoLayer(codec: .hevc, pixels: PixelSize(width: 3840, height: 2160), bitrate: 100_000_000)
        let encoder = try XCTUnwrap(VideoEncoder(layer: layer))
        var params: [Data] = []
        var frames: [(keyframe: Bool, avcc: Data)] = []
        encoder.onParams = { _, sets in params = sets }
        encoder.onFrame = { frames.append(($0, $1)) }
        let source = try frame(width: 5120, height: 2880, bgra: (40, 120, 200))

        XCTAssertTrue(encoder.encode(source, time: 10, forceKeyframe: true))
        XCTAssertEqual(frames.count, 1, "the frame arrives before encode returns")
        XCTAssertTrue(frames[0].keyframe)
        XCTAssertFalse(params.isEmpty)
        XCTAssertTrue(encoder.encode(source, time: 10 + 1.0 / 60, forceKeyframe: false))
        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(frames[1].keyframe, "no periodic keyframes")

        let picture = try decode(params: params, sample: frames[0].avcc)
        XCTAssertEqual(picture.width, 3840)
        XCTAssertEqual(picture.height, 2160)
        // BT.709 video range: 16 + 219 × (0.2126 R + 0.7152 G + 0.0722 B) / 255
        XCTAssertEqual(picture.centreY, 129, accuracy: 4)
    }
}
