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
    /// 0 on built-in panels
    var refreshRate: Double = 0
}

public enum HardwareInfo {
    public static func marketingName(modelID: String) -> String {
        MacModels.name(for: modelID)
    }

    /// Points at the panel's backing scale: 2 on Retina
    public static func points(forPanel p: PixelSize, scale: Int) -> PixelSize {
        let s = max(1, scale)
        return PixelSize(width: p.width / s, height: p.height / s)
    }

    /// Display's backing scale, as macOS drives it
    /// No screen yet: 2 if a HiDPI mode spans native pixels
    public static func backingScale(_ id: CGDirectDisplayID) -> Int {
        if let scale = NSScreen.screens.first(where: { $0.displayID == id })?.backingScaleFactor { return Int(scale.rounded()) }
        let panel = panelPixels(id)
        return displayModes(id).map(info).contains { $0.pixelWidth == panel.width && $0.width * 2 == panel.width } ? 2 : 1
    }

    /// Display's highest refresh; nil when it reports none
    /// Built-in panels report 0 through the display mode
    static func refreshHz(_ id: CGDirectDisplayID) -> Double? {
        if #available(macOS 12, *), let fps = NSScreen.screens.first(where: { $0.displayID == id })?.maximumFramesPerSecond, fps > 0 {
            return Double(fps)
        }
        let rate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return rate > 0 ? rate : nil
    }

    /// Display's size in mm; nil when it reports none
    static func panelMillimeters(_ id: CGDirectDisplayID) -> PixelSize? {
        let mm = CGDisplayScreenSize(id)
        return mm.width > 0 && mm.height > 0 ? PixelSize(width: Int(mm.width.rounded()), height: Int(mm.height.rounded())) : nil
    }

    /// Native pixel size of a display
    public static func panelPixels(_ id: CGDirectDisplayID) -> PixelSize {
        nativePanel(displayModes(id).map(info), current: CGDisplayCopyDisplayMode(id).map(info))
            ?? PixelSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }

    static func displayModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        isNative: mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0, refreshRate: mode.refreshRate)
    }

    /// Native or 1:1 modes only
    /// Scaled HiDPI backing can exceed the panel size
    /// `current` counts when 1:1: some monitors flag a smaller native
    static func nativePanel(_ modes: [DisplayModeInfo], current: DisplayModeInfo? = nil) -> PixelSize? {
        let native = modes.filter(\.isNative)
        let candidates = (native.isEmpty ? modes.filter { $0.width == $0.pixelWidth } : native)
            + [current].compactMap { $0 }.filter { $0.width == $0.pixelWidth }
        return candidates.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
            .map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    /// A full-screen Space ends this far below the safe area
    static let spaceGap: CGFloat = 1

    /// Panel pixels below a camera notch
    /// `safeTop` over `screenHeight`: points of any mode, same share
    /// Height a multiple of four, as streams are
    static func belowNotch(_ panel: PixelSize, screenHeight: CGFloat, safeTop: CGFloat) -> PixelSize {
        guard safeTop > 0, screenHeight > 0 else { return panel }
        let notch = Int((CGFloat(panel.height) * (safeTop + spaceGap) / screenHeight).rounded())
        return PixelSize(width: panel.width, height: (panel.height - notch) / 4 * 4)
    }

    /// The stream's share of the panel: below the notch
    static func streamPanel(_ id: CGDirectDisplayID) -> PixelSize {
        let panel = panelPixels(id)
        guard #available(macOS 12, *), let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return panel }
        return belowNotch(panel, screenHeight: screen.frame.height, safeTop: screen.safeAreaInsets.top)
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
    /// Kaby Lake and later Intel Macs, and Apple silicon
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

    /// What a sender learns of `display`
    /// Size and millimetres: the part below a notch
    /// `switching`: scale and refresh of the mode streams switch to
    public static func welcome(name: String, display id: CGDirectDisplayID, switching: Bool = false) -> Welcome {
        let full = panelPixels(id), panel = streamPanel(id)
        let next = switching ? PanelMode.target(id) : nil
        let scale = next.map { max(1, $0.pixelWidth / max(1, $0.width)) } ?? backingScale(id)
        let refresh = next.flatMap { $0.refreshRate > 0 ? $0.refreshRate : nil } ?? refreshHz(id)
        let mm = panelMillimeters(id).map { PixelSize(width: $0.width, height: $0.height * panel.height / max(1, full.height)) }
        let model = HardwareModel.identifier
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var welcome = Welcome(protocolVersion: AfterscreenProtocol.version, name: name, modelID: model,
                              marketingName: marketingName(modelID: model),
                              osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                              gpuNames: gpuNames(), panelPixels: panel, panelPoints: points(forPanel: panel, scale: scale),
                              hevcDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                              h264Decode: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                              bc7: true, hevcMain10Decode: hevcMain10Decode, audioPlayback: true, panelMillimeters: mm,
                              refreshHz: refresh)
        welcome.appVersion = AppVersion.current
        return welcome
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
