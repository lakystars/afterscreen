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

    /// Retina panels (≥ 3000 px wide) run HiDPI at half the pixels
    public static func points(forPanel p: PixelSize) -> PixelSize {
        p.width >= 3000 ? PixelSize(width: p.width / 2, height: p.height / 2) : p
    }

    /// Native pixel size of the main display
    public static func panelPixels() -> PixelSize {
        let id = CGMainDisplayID()
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = ((CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []).map {
            DisplayModeInfo(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                            isNative: $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0)
        }
        return nativePanel(modes) ?? PixelSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }

    /// Scaled HiDPI modes can have a larger backing than the panel, so only native or 1:1 modes count
    static func nativePanel(_ modes: [DisplayModeInfo]) -> PixelSize? {
        let native = modes.filter(\.isNative)
        let candidates = native.isEmpty ? modes.filter { $0.width == $0.pixelWidth } : native
        return candidates.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
            .map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }

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
                       gpuNames: gpuNames(), panelPixels: panel, panelPoints: points(forPanel: panel),
                       hevcDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                       h264Decode: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                       bc7: true)
    }
}
