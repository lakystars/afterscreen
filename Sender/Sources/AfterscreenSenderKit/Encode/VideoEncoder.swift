import CoreMedia
import Foundation
import AfterscreenCore
import VideoToolbox

/// Real-time HEVC/H.264 encoder for the hybrid path's video layer
/// Pipelined: about 15 ms per 4K frame
/// Next frame submitted before the previous one finishes
final class VideoEncoder {
    enum Output {
        /// Parameter sets on every keyframe; a reset decoder recovers
        case frame(keyframe: Bool, avcc: Data, parameterSets: [Data])
        /// Skipped under load; receiver keeps the previous picture
        case dropped
        case failed
    }

    private let layer: VideoLayer
    private let session: VTCompressionSession
    /// Scales captured frames to layer size into the encoder pool
    private var transfer: VTPixelTransferSession?

    init?(layer: VideoLayer, fps: Double) {
        self.layer = layer
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: layer.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: layer.pixels.width,
            kCVPixelBufferHeightKey: layer.pixels.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        // Regular pipelined mode instead of low-latency rate control
        // Low-latency is serial: about 47 fps at 4K, M5 Pro
        // It also emits nothing for H.264 High
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
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // TCP is lossless; receiver requests a keyframe on decode failure
            // Both limits at 0 ("none"): HEVC keys every 30 frames
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

    /// Encoding queue; applies from the next frames
    func setBitrate(_ bitsPerSecond: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
    }

    /// `time` in seconds; frames arrive only during motion
    /// Timestamps therefore carry the gaps
    /// `completion`: once per accepted frame, submission order, encoder thread
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

    /// Captured frame as 4:2:0 BT.709 at layer size
    /// Buffer comes from the encoder pool
    /// Always via the transfer session
    /// sRGB-tagged RGB input makes the encoder apply the BT.709 curve
    /// The receiver does not undo that curve
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
        // Recycled pool buffers lose the BT.709 transfer tag
        // but keep the capture's sRGB colour space
        // Encoder would then apply the BT.709 curve
        // Tag every frame with the stream's colour attributes
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
