import CoreMedia
import Foundation
import AfterscreenCore
import VideoToolbox

/// Real-time HEVC/H.264 encoder emitting AVCC samples and parameter sets
final class VideoEncoder {
    var onParams: ((VideoCodec, [Data]) -> Void)?
    var onFrame: ((Bool, Data) -> Void)?
    private(set) var lastEncodeMs = 0.0

    private let codec: VideoCodec
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0

    init?(codec: VideoCodec, size: PixelSize, bitrate: Int) {
        self.codec = codec
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else { return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        for (key, value) in props { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        if let s = session { VTCompressionSessionInvalidate(s) }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let session = session else { return }
        let start = Date()
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 60)
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self = self, status == noErr, let sample = sample else { return }
            self.lastEncodeMs = Date().timeIntervalSince(start) * 1000
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        // Every keyframe carries its parameter sets so a receiver that reset its decoder recovers
        if keyframe, let format = sample.formatDescription {
            onParams?(codec, parameterSets(format))
        }
        guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return }
        onFrame?(keyframe, data)
    }

    private func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        return (0..<count).compactMap { i in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let p = pointer else { return nil }
            return Data(bytes: p, count: size)
        }
    }
}
