import CoreMedia
import Foundation
import AfterscreenCore
import VideoToolbox

/// Real-time HEVC/H.264 encoder for the hybrid path's video layer.
/// Synchronous: parameter sets and the frame reach the callbacks before `encode` returns
final class VideoEncoder {
    var onParams: ((VideoCodec, [Data]) -> Void)?
    var onFrame: ((Bool, Data) -> Void)?
    private(set) var lastEncodeMs = 0.0

    private let layer: VideoLayer
    private let session: VTCompressionSession
    /// Scales captured frames to the layer size, into the encoder's own buffer pool
    private var transfer: VTPixelTransferSession?

    init?(layer: VideoLayer) {
        self.layer = layer
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: layer.pixels.width,
            kCVPixelBufferHeightKey: layer.pixels.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        func make(lowLatency: Bool) -> VTCompressionSession? {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(layer.pixels.width), height: Int32(layer.pixels.height),
                                                    codecType: layer.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                    encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return status == noErr ? s : nil
        }
        // Low-latency rate control is not offered for every codec on every Mac
        guard let session = make(lowLatency: true) ?? make(lowLatency: false) else { return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: layer.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: layer.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            // TCP loses nothing; the receiver asks for a keyframe when decoding fails
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 0,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0,
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
    /// false when the frame was not encoded
    func encode(_ pixelBuffer: CVPixelBuffer, time: TimeInterval, forceKeyframe: Bool) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        guard let input = scaled(pixelBuffer) else { return false }
        let pts = CMTime(seconds: time, preferredTimescale: 1_000_000)
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        var emitted = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: input, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample = sample, let self = self else { return }
            emitted = self.emit(sample)
        }
        guard status == noErr else { return false }
        // Returns once the output handler has run
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        lastEncodeMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return emitted
    }

    /// The captured frame when it already has the layer size, else a scaled 4:2:0 copy
    private func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(source) == layer.pixels.width && CVPixelBufferGetHeight(source) == layer.pixels.height { return source }
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
        return target
    }

    private func emit(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        // Every keyframe carries its parameter sets so a receiver that reset its decoder recovers
        if keyframe, let format = sample.formatDescription {
            onParams?(layer.codec, parameterSets(format))
        }
        guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return false }
        onFrame?(keyframe, data)
        return true
    }

    private func parameterSets(_ format: CMFormatDescription) -> [Data] {
        let hevc = layer.codec == .hevc
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
