import AppKit
import Metal
import AfterscreenCore
import VideoToolbox

struct DisplayModeInfo {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var isNative: Bool
}

public enum HardwareInfo {
    private static let names: [String: String] = [
        "iMac14,1": "iMac 21.5\" (Late 2013)",
        "iMac14,2": "iMac 27\" (Late 2013)",
        "iMac14,3": "iMac 21.5\" (Late 2013)",
        "iMac14,4": "iMac 21.5\" (Mid 2014)",
        "iMac15,1": "iMac 27\" 5K (2014–2015)",
        "iMac16,1": "iMac 21.5\" (Late 2015)",
        "iMac16,2": "iMac 21.5\" 4K (Late 2015)",
        "iMac17,1": "iMac 27\" 5K (Late 2015)",
        "iMac18,1": "iMac 21.5\" (2017)",
        "iMac18,2": "iMac 21.5\" 4K (2017)",
        "iMac18,3": "iMac 27\" 5K (2017)",
        "iMac19,1": "iMac 27\" 5K (2019)",
        "iMac19,2": "iMac 21.5\" 4K (2019)",
        "iMac20,1": "iMac 27\" 5K (2020)",
        "iMac20,2": "iMac 27\" 5K (2020)",
        "iMacPro1,1": "iMac Pro (2017)",
        "iMac21,1": "iMac 24\" (M1, 2021)",
        "iMac21,2": "iMac 24\" (M1, 2021)",
    ]

    public static func marketingName(modelID: String) -> String {
        names[modelID] ?? modelID
    }

    /// Points at the panel's backing scale: 2 on Retina
    public static func points(forPanel p: PixelSize, scale: Int) -> PixelSize {
        let s = max(1, scale)
        return PixelSize(width: p.width / s, height: p.height / s)
    }

    private static var mainScreen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID() }
    }

    /// Main display's backing scale, as macOS drives it
    /// No screen yet: 2 if a HiDPI mode spans native pixels
    public static var backingScale: Int {
        if let scale = mainScreen?.backingScaleFactor { return Int(scale.rounded()) }
        let panel = panelPixels()
        return displayModes().contains { $0.pixelWidth == panel.width && $0.width * 2 == panel.width } ? 2 : 1
    }

    /// Main display's highest refresh; nil when it reports none
    /// Built-in panels report 0 through the display mode
    static func refreshHz() -> Double? {
        if #available(macOS 12, *), let fps = mainScreen?.maximumFramesPerSecond, fps > 0 { return Double(fps) }
        let rate = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        return rate > 0 ? rate : nil
    }

    /// Main display's size in mm; nil when it reports none
    static func panelMillimeters() -> PixelSize? {
        let mm = CGDisplayScreenSize(CGMainDisplayID())
        return mm.width > 0 && mm.height > 0 ? PixelSize(width: Int(mm.width.rounded()), height: Int(mm.height.rounded())) : nil
    }

    /// Native pixel size of the main display
    public static func panelPixels() -> PixelSize {
        let id = CGMainDisplayID()
        return nativePanel(displayModes()) ?? PixelSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }

    private static func displayModes() -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return ((CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options) as? [CGDisplayMode]) ?? []).map {
            DisplayModeInfo(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                            isNative: $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0)
        }
    }

    /// Native or 1:1 modes only
    /// Scaled HiDPI backing can exceed the panel size
    static func nativePanel(_ modes: [DisplayModeInfo]) -> PixelSize? {
        let native = modes.filter(\.isNative)
        let candidates = native.isEmpty ? modes.filter { $0.width == $0.pixelWidth } : native
        return candidates.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
            .map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    /// 3840×2160 HEVC Main10 parameter sets (VPS, SPS, PPS)
    /// Encoded by VideoToolbox on the sender
    private static let main10Probe: [[UInt8]] = [
        [0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
         0x99, 0x15, 0xc0, 0x90],
        [0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xa0, 0x01,
         0xe0, 0x20, 0x02, 0x1c, 0x4d, 0x88, 0x15, 0xee, 0x45, 0x95, 0x10],
        [0x44, 0x01, 0xc0, 0x2c, 0xbd, 0x14, 0xd9],
    ]

    /// Whether a hardware decoder accepts a 4K Main10 stream
    /// Kaby Lake and later Intel iMacs, and Apple silicon
    public static let hevcMain10Decode: Bool = {
        var format: CMVideoFormatDescription?
        let created: OSStatus = main10Probe.withPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                formatDescriptionOut: &format)
        }
        guard created == noErr, let description = format else { return false }
        var session: VTDecompressionSession?
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: spec,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let decoder = session else { return false }
        VTDecompressionSessionInvalidate(decoder)
        return true
    }()

    public static func gpuNames() -> [String] {
        let names = MTLCopyAllDevices().map(\.name)
        return names.isEmpty ? ["Unknown GPU"] : names
    }

    public static func welcome(name: String) -> Welcome {
        let panel = panelPixels()
        let model = HardwareModel.identifier
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Welcome(protocolVersion: AfterscreenProtocol.version, name: name, modelID: model,
                       marketingName: marketingName(modelID: model),
                       osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                       gpuNames: gpuNames(), panelPixels: panel, panelPoints: points(forPanel: panel, scale: backingScale),
                       hevcDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                       h264Decode: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                       bc7: true, hevcMain10Decode: hevcMain10Decode, audioPlayback: true, panelMillimeters: panelMillimeters(),
                       refreshHz: refreshHz())
    }
}

private extension Array where Element == [UInt8] {
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = map { bytes -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            p.initialize(from: bytes, count: bytes.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, map(\.count))
    }
}
