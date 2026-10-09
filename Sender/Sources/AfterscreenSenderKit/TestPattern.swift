import CoreVideo
import Metal
import AfterscreenCore

/// Full-motion test frames: every pixel changes every frame; smooth colour, rings and fine stripes,
/// the worst case for both the tile and the video encoder
final class TestPattern {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var pool: (size: PixelSize, pool: CVPixelBufferPool)?

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void testPattern(texture2d<float, access::write> out [[texture(0)]],
                            constant float &t [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width(), h = out.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float2 p = float2(gid) / float(h);
        float3 c = 0.5 + 0.5 * cos(6.2832 * (p.x * 0.8 + p.y * 0.5 + t * 0.4 + float3(0.0, 0.33, 0.67)));
        float2 centre = float2(0.5 * float(w) / float(h) + 0.35 * cos(t * 1.3), 0.5 + 0.3 * sin(t * 1.7));
        c *= 0.7 + 0.3 * cos(length(p - centre) * 80.0 - t * 10.0);
        // Text-like detail: moving one-pixel stripes in every fourth 24 px band
        if ((gid.y / 24) % 4 == 1) {
            uint phase = gid.x + uint(t * 300.0);
            c = mix(c, float3(float(((phase / 2) & 1) ^ ((gid.y / 3) & 1))), 0.7);
        }
        out.write(float4(c, 1.0), gid);
    }
    """

    init?() {
        var cache: CVMetalTextureCache?
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let function = (try? device.makeLibrary(source: TestPattern.source, options: nil))?.makeFunction(name: "testPattern"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.cache = textureCache
    }

    /// nil while 4 frames of this size are still in use downstream
    func frame(size: PixelSize, time: Double) -> CVPixelBuffer? {
        if pool?.size != size {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &created) == kCVReturnSuccess, let p = created else { return nil }
            pool = (size, p)
        }
        var pb: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard let pool = pool?.pool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        var cvTexture: CVMetalTexture?
        let usage = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, usage, .bgra8Unorm, size.width, size.height, 0, &cvTexture)
        guard let texture = cvTexture.flatMap(CVMetalTextureGetTexture), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        var t = Float(time)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setBytes(&t, length: 4, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (size.width + 15) / 16, height: (size.height + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return buffer
    }
}
