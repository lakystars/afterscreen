import CoreGraphics
import Foundation
import Metal
import AfterscreenCore

/// GPU the receiver draws with
/// Two-GPU MacBook Pro: discrete only while streaming its panel
/// Else the GPU driving the screen: no copy between GPUs
enum GPUChoice {
    struct GPU: Equatable {
        var id: UInt64
        var lowPower: Bool
        var headless: Bool
        var removable: Bool
    }

    enum Kind { case integrated, discrete }

    /// Integrated and discrete GPUs that macOS switches between
    /// 15-, 16-inch MacBook Pro: the model rules out iMacs
    static func switching(_ gpus: [GPU], model: String) -> Bool {
        let shown = gpus.filter { !$0.headless && !$0.removable }
        return model.hasPrefix("MacBookPro") && shown.contains(where: \.lowPower) && shown.contains { !$0.lowPower }
    }

    /// Between sessions: integrated, never holding the discrete one
    /// Streaming its own panel: discrete, requested from macOS
    /// A monitor on its ports: the discrete GPU drives it
    static func preference(switching: Bool, builtIn: Bool, streaming: Bool) -> Kind? {
        guard switching else { return nil }
        guard streaming else { return .integrated }
        return builtIn ? .discrete : nil
    }

    /// `driving`: the GPU showing the screen now
    static func pick(_ gpus: [GPU], driving: UInt64?, prefer kind: Kind?) -> UInt64? {
        if let kind = kind,
           let gpu = gpus.first(where: { $0.lowPower == (kind == .integrated) && !$0.headless && !$0.removable }) {
            return gpu.id
        }
        return gpus.first { $0.id == driving }?.id
    }

    static func kind(for display: CGDirectDisplayID, streaming: Bool) -> Kind? {
        preference(switching: switching(gpus(MTLCopyAllDevices()), model: HardwareModel.identifier),
                   builtIn: CGDisplayIsBuiltin(display) != 0, streaming: streaming)
    }

    /// Enumerating devices switches no GPU, the default device does
    /// No GPU drives `display`: integrated if switching, else default
    static func device(for display: CGDirectDisplayID, streaming: Bool) -> MTLDevice? {
        let all = MTLCopyAllDevices(), gpus = gpus(all)
        let switches = switching(gpus, model: HardwareModel.identifier)
        let kind = preference(switching: switches, builtIn: CGDisplayIsBuiltin(display) != 0, streaming: streaming)
        let id = pick(gpus, driving: CGDirectDisplayCopyCurrentMetalDevice(display)?.registryID, prefer: kind)
            ?? (switches ? pick(gpus, driving: nil, prefer: .integrated) : nil)
        return all.first { $0.registryID == id } ?? MTLCreateSystemDefaultDevice()
    }

    private static func gpus(_ devices: [MTLDevice]) -> [GPU] {
        devices.map { GPU(id: $0.registryID, lowPower: $0.isLowPower, headless: $0.isHeadless, removable: $0.isRemovable) }
    }

    static func drivingName(_ display: CGDirectDisplayID) -> String {
        CGDirectDisplayCopyCurrentMetalDevice(display)?.name ?? "no GPU"
    }
}

/// Moves a two-GPU MacBook Pro's panel to the discrete GPU
/// An OpenGL pixel format without offline renderers requests it
/// Released, macOS may switch back; Metal devices live on
final class DiscreteGPURequest {
    private typealias Choose = @convention(c) (UnsafePointer<UInt32>, UnsafeMutablePointer<OpaquePointer?>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Release = @convention(c) (OpaquePointer) -> Void
    private static let gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
    private static let choose = gl.flatMap { dlsym($0, "CGLChoosePixelFormat") }.map { unsafeBitCast($0, to: Choose.self) }
    private static let releaseFormat = gl.flatMap { dlsym($0, "CGLReleasePixelFormat") }.map { unsafeBitCast($0, to: Release.self) }
    private var format: OpaquePointer?

    var isHeld: Bool { format != nil }

    func hold() {
        guard format == nil, let choose = DiscreteGPURequest.choose else { return }
        let attributes: [UInt32] = [0]
        var count: Int32 = 0
        _ = choose(attributes, &format, &count)
    }

    func release() {
        guard let held = format else { return }
        DiscreteGPURequest.releaseFormat?(held)
        format = nil
    }
}
