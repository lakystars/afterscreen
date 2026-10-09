import Metal
import AfterscreenCore
@testable import AfterscreenSenderKit

/// Uploads encoder output into a real BC7 texture and reads it back through the GPU sampler
struct HardwareBC7Probe {
    let device: MTLDevice

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void readBack(texture2d<float> src [[texture(0)]],
                         device uchar4 *out [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        uint w = src.get_width(), h = src.get_height();
        if (gid.x >= w || gid.y >= h) return;
        constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
        float4 v = src.sample(s, float2(gid) + 0.5);
        out[gid.y * w + gid.x] = uchar4(round(saturate(v) * 255.0));
    }
    """

    func decode(_ encoder: TileEncoder, geometry g: TileGeometry) throws -> [UInt8] {
        let bytes = encoder.reference
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm, width: g.width, height: g.height, mipmapped: false)
        desc.usage = .shaderRead
        let tex = device.makeTexture(descriptor: desc)!
        // Tile-major → linear block rows
        var linear = [UInt8](repeating: 0, count: g.blocksX * g.blocksY * 16)
        for by in 0..<g.blocksY {
            for bx in 0..<g.blocksX {
                let src = TileEncoder.blockOffset(bx: bx, by: by, geometry: g)
                let dst = (by * g.blocksX + bx) * 16
                for i in 0..<16 { linear[dst + i] = bytes[src + i] }
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, g.width, g.height), mipmapLevel: 0, withBytes: linear, bytesPerRow: g.blocksX * 16)
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "readBack")!)
        let out = device.makeBuffer(length: g.width * g.height * 4, options: .storageModeShared)!
        let queue = device.makeCommandQueue()!
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: g.width, height: g.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt8.self), count: g.width * g.height * 4))
    }
}
