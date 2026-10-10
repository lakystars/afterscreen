import CoreMedia
import CoreVideo
import Foundation
import AfterscreenCore
import ScreenCaptureKit

/// Captured frame; changed regions in output pixels, nil if unknown
struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    var dirty: [CGRect]?

    /// More merged regions than this: unknown, all tiles
    static let maxRegions = 256

    /// Frame replacing an unsent one carries both frames' regions
    static func merge(_ dropped: [CGRect]?, into newer: [CGRect]?) -> [CGRect]? {
        guard let dropped = dropped, let newer = newer, dropped.count + newer.count <= maxRegions else { return nil }
        return newer + dropped
    }
}

/// ScreenCaptureKit stream of one display; skips frames without new content
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapturedFrame) -> Void)?
    var onStop: ((String) -> Void)?
    let captured = RateCounter()

    private let displayID: CGDirectDisplayID
    private let size: PixelSize
    private let crop: CGRect?
    private let queue = DispatchQueue(label: "afterscreen.capture", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private var stream: SCStream?

    /// `crop`: display points captured; nil for the whole display
    init(displayID: CGDirectDisplayID, size: PixelSize, crop: CGRect? = nil) {
        self.displayID = displayID
        self.size = size
        self.crop = crop
    }

    /// 8-bit BGRA: BC7 tiles hold 8 bits per channel
    /// 10-bit capture adds WindowServer work, no levels
    /// sRGB keeps SDR colour
    static func configuration(size: PixelSize, crop: CGRect? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 3
        // Ceiling, not target: display composites only as fast as consumed
        // 60 Hz ceiling drops ProMotion frames; the gate paces sends
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        if let crop = crop { config.sourceRect = crop }
        return config
    }

    /// Retries: virtual display appears in shareable content with delay
    func start(completion: @escaping (Error?) -> Void) {
        Task {
            do {
                var display: SCDisplay?
                for _ in 0..<20 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    display = content.displays.first { $0.displayID == displayID }
                    if display != nil { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard let display = display else {
                    throw NSError(domain: "Afterscreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not visible to ScreenCaptureKit"])
                }
                let config = Capture.configuration(size: size, crop: crop)
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        guard let stream = stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        captured.tick()
        onFrame?(CapturedFrame(pixelBuffer: pixelBuffer, dirty: Capture.dirtyRects(info, outputWidth: CVPixelBufferGetWidth(pixelBuffer))))
    }

    private static func dirtyRects(_ info: [SCStreamFrameInfo: Any], outputWidth: Int) -> [CGRect]? {
        guard let rects = info[.dirtyRects] as? [NSDictionary],
              let content = (info[.contentRect] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              let scale = info[.scaleFactor] as? CGFloat else { return nil }
        return scaled(rects.compactMap { CGRect(dictionaryRepresentation: $0) }, content: content, scale: scale, outputWidth: outputWidth)
    }

    /// Dirty rects arrive in display pixels
    /// `content` (points) × `scale` maps onto the output width
    static func scaled(_ rects: [CGRect], content: CGRect, scale: CGFloat, outputWidth: Int) -> [CGRect]? {
        let k = CGFloat(outputWidth) / (content.width * scale)
        guard scale > 0, content.width > 0, k.isFinite, k > 0 else { return nil }
        let ox = content.minX * scale, oy = content.minY * scale
        return rects.filter { !$0.isEmpty }.map {
            let r = CGRect(x: ($0.minX - ox) * k, y: ($0.minY - oy) * k, width: $0.width * k, height: $0.height * k)
            return k == 1 ? r : r.integral
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error.localizedDescription)
    }
}
