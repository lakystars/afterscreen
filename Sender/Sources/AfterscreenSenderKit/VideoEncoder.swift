import CoreMedia
import Foundation
import AfterscreenCore
import VideoToolbox

/// Real-time HEVC/H.264 encoder for the hybrid path's video layer.
/// Pipelined: a frame takes about 15 ms at 4K, so the next one is submitted before it finishes
final class VideoEncoder {
    enum Output {
        /// Parameter sets come with every keyframe, so a receiver that reset its decoder recovers
        case frame(keyframe: Bool, avcc: Data, parameterSets: [Data])
        /// Skipped by the encoder under load; the receiver keeps the previous picture
        case dropped
        case failed
    }

    private let layer: VideoLayer
    private let session: VTCompressionSession
    /// Scales captured frames to the layer size, into the encoder's own buffer pool
    private var transfer: VTPixelTransferSession?

    init?(layer: VideoLayer) {
        self.layer = layer
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: layer.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: layer.pixels.width,
            kCVPixelBufferHeightKey: layer.pixels.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        // Low-latency rate control encodes one frame at a time (about 47 fps at 4K on M5 Pro) and
        // emits nothing for H.264 High, so the regular pipelined mode is used
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(layer.pixels.width), height: Int32(layer.pixels.height),
                                         codecType: layer.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                         encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                         imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let session = s else { return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: layer.codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel
                : (layer.tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel),
            kVTCompressionPropertyKey_AverageBitRate: layer.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            // TCP loses nothing; the receiver asks for a keyframe when decoding fails.
            // With both limits at 0 ("none") the HEVC encoder keys every 30 frames
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 86_400,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in props { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// `time` in seconds; frames arrive only while something moves, so timestamps carry the gaps.
    /// `completion` runs once per accepted frame, in submission order, on an encoder thread.
    /// false when the frame was not accepted
    func encode(_ pixelBuffer: CVPixelBuffer, time: TimeInterval, forceKeyframe: Bool, completion: @escaping (Output) -> Void) -> Bool {
        guard let input = scaled(pixelBuffer) else { return false }
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let codec = layer.codec
        return VTCompressionSessionEncodeFrame(session, imageBuffer: input, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000),
                                               duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, flags, sample in
            guard status == noErr else { return completion(.failed) }
            guard let sample = sample else { return completion(flags.contains(.frameDropped) ? .dropped : .failed) }
            completion(VideoEncoder.output(sample, codec: codec))
        } == noErr
    }

    /// The captured frame as 4:2:0 BT.709 at the layer size, in the encoder's pool. Always through the transfer session:
    /// handed an sRGB-tagged RGB buffer, the encoder would also convert to the BT.709 curve the receiver does not undo
    private func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil {
            var t: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t) == noErr, let created = t else { return nil }
            VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            transfer = created
        }
        var out: CVPixelBuffer?
        guard let pool = VTCompressionSessionGetPixelBufferPool(session),
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let target = out, let transfer = transfer,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: target) == noErr else { return nil }
        // Recycled pool buffers lose the BT.709 transfer tag but keep the capture's sRGB colour space,
        // and the encoder would then convert to the BT.709 curve: tag every frame as the stream
        CVBufferRemoveAttachment(target, kCVImageBufferCGColorSpaceKey)
        CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return target
    }

    private static func output(_ sample: CMSampleBuffer, codec: VideoCodec) -> Output {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return .failed }
        let sets = keyframe ? sample.formatDescription.map { parameterSets($0, codec: codec) } ?? [] : []
        return .frame(keyframe: keyframe, avcc: data, parameterSets: sets)
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        let hevc = codec == .hevc
        var count = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        return (0..<count).compactMap { i in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let p = pointer else { return nil }
            return Data(bytes: p, count: size)
        }
    }
}
