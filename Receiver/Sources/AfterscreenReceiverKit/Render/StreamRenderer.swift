import CoreMedia
import CoreVideo
import Metal
import AfterscreenCore
import QuartzCore
import VideoToolbox

/// Draws the current picture into a CAMetalLayer, letterboxed
/// BC7 tile texture, plus hybrid video in masked tiles
/// Decode queue unless a method says otherwise
final class StreamRenderer {
    let layer = CAMetalLayer()
    let gpuMeter = GPUTimeMeter()
    let displayed = RateCounter()
    /// Telemetry written on the decode queue, read elsewhere
    private let statsLock = NSLock()
    private var stats = (late: 0, uploadMs: 0.0, decodeMs: 0.0)
    var lateFrames: Int { statsLock.lock(); defer { statsLock.unlock() }; return stats.late }
    var uploadMs: Double { statsLock.lock(); defer { statsLock.unlock() }; return stats.uploadMs }
    var decodeMs: Double { statsLock.lock(); defer { statsLock.unlock() }; return stats.decodeMs }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let tilePipeline: MTLRenderPipelineState
    private let hybridPipeline: MTLRenderPipelineState
    private let tileTexture: TileTexture
    /// nil if the deband kernel fails to build: no debanding
    private let debandCache: DebandCache?
    private var textureCache: CVMetalTextureCache?
    private var decoder: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    /// Latest decoded video picture (NV12 planes)
    /// Each draw sampling it retains it until completion
    private var video: (luma: CVMetalTexture, chroma: CVMetalTexture)?
    private var mask = VideoMask()
    /// Main10: decoded planes are 16-bit, 10 bits used
    private var tenBit = false
    /// 10 bits per channel: iMac panels take 10-bit input
    /// Dithered BC7 and Main10 video keep their steps
    static let drawableFormat = MTLPixelFormat.bgr10a2Unorm
    /// Ring of 3: with 2 drawables, a buffer's last draw
    /// completes before the buffer is reused
    private var maskBuffers: [MTLBuffer] = []
    private var maskRing = 0
    private let sizeLock = NSLock()
    private var drawableSize = CGSize.zero
    private var insetPixels: CGFloat = 0
    /// First-pass deband radius in texels; under `sizeLock`
    private var debandRange = Deband.normal.rangePixels
    /// The next draw also goes to a PNG in /tmp
    private var snapshotRequested = false
    /// False while on another Space or covered
    /// Tiles still upload; nothing draws
    /// Avoids waiting on drawables the compositor withholds
    private var isVisible = true
    /// Decode queue: the stream size, for redraws
    private var lastGeometry: TileGeometry?
    /// Power effect, under `sizeLock`; nil draws the picture as sent
    private var wave: Wave?
    /// Kept past its session for a closing wave; under `sizeLock`
    private var farewell: (texture: MTLTexture, tilePixels: Int)?
    /// Time of the last presented picture; under `statsLock`
    /// Effect redraws skip frames the stream already drew
    private var lastDraw: CFTimeInterval = 0

    /// Tile wave: black, opening centre-out, or closing corners-in
    enum Wave: Equatable {
        case hidden
        case opening(start: CFTimeInterval, duration: CFTimeInterval)
        case closing(start: CFTimeInterval, duration: CFTimeInterval)

        /// `Wave` in the shaders
        struct Parameters {
            var progress: Float
            var active: Float
            var closing: Float
            var tilePixels: Float
            var size: SIMD2<Float>
        }

        /// The picture as sent
        static let still = Parameters(progress: 0, active: 0, closing: 0, tilePixels: 64, size: SIMD2(1, 1))

        /// 0…1 through the wave; nil once an opening is over
        /// Closing holds at 1 until the window goes
        func progress(at now: CFTimeInterval) -> Float? {
            switch self {
            case .hidden:
                return 0
            case let .opening(start, duration):
                let p = (now - start) / max(duration, 0.001)
                return p >= 1 ? nil : Float(max(0, p))
            case let .closing(start, duration):
                return Float(min(1, max(0, (now - start) / max(duration, 0.001))))
            }
        }

        func parameters(at now: CFTimeInterval, tilePixels: Int, size: CGSize) -> Parameters {
            guard let p = progress(at: now) else { return Wave.still }
            var closing: Float = 0
            if case .closing = self { closing = 1 }
            return Parameters(progress: p, active: 1, closing: closing, tilePixels: Float(tilePixels),
                              size: SIMD2(Float(size.width), Float(size.height)))
        }
    }

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut screenQuad(uint vid [[vertex_id]]) {
        float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
        VOut o;
        o.position = float4(p, 0.0, 1.0);
        o.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return o;
    }

    // Deband: sources often draw dark gradients in undithered 8-bit steps
    // Each pass: 4 samples symmetric around the pixel, growing radius
    // On a gradient their mean is the unstepped value
    // Pass accepted if mean within 1 level of the pixel
    // and every sample within 3 levels; accepted passes are averaged
    // The 10-bit drawable keeps the in-between values
    // Edges and text fail the sample limit and pass unchanged
    // Point sampling keeps partial edge mixes out
    // `range`: first-pass radius in texels, 0 for off
    constant float kDebandMeanLimit = 1.0 / 255.0;
    constant float kDebandSampleLimit = 3.0 / 255.0;
    constant int kDebandIterations = 3;

    // Per-pixel pseudo-random value in [0, 1)
    // Stable: each pixel gets the same offsets every frame
    static inline float hash01(uint2 p, uint i) {
        uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ i * 0xcb1ab31fu;
        h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
        return float(h) * (1.0 / 4294967296.0);
    }

    static float3 deband(texture2d<float> tex, float2 uv, float3 color, float range) {
        if (range <= 0.0) return color;
        constexpr sampler point(filter::nearest, address::clamp_to_edge);
        float2 size = float2(tex.get_width(), tex.get_height());
        uint2 p = uint2(uv * size);
        float3 sum = color;
        float n = 1.0;
        for (int i = 1; i <= kDebandIterations; i++) {
            float dist = hash01(p, uint(2 * i)) * range * float(i);
            float dir = hash01(p, uint(2 * i + 1)) * 6.2831853;
            float2 o = dist * float2(cos(dir), sin(dir)) / size;
            float3 a = tex.sample(point, uv + o).rgb, b = tex.sample(point, uv + float2(-o.y, o.x)).rgb;
            float3 c = tex.sample(point, uv - o).rgb, d = tex.sample(point, uv + float2(o.y, -o.x)).rgb;
            float3 ring = a + b + c + d;
            float3 spread = max(max(abs(a - color), abs(b - color)), max(abs(c - color), abs(d - color)));
            if (any(abs(ring * 0.25 - color) > kDebandMeanLimit) || any(spread > kDebandSampleLimit)) continue;
            sum += ring;
            n += 4.0;
        }
        return sum / n;
    }

    struct DebandGrid { uint width; uint height; uint tilesX; uint tilePixels; float range; };

    // Grid (tilePixels, tilePixels, tiles): a thread per tile pixel
    kernel void debandTiles(texture2d<float> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant DebandGrid &g [[buffer(0)]],
                            device const uint *tiles [[buffer(1)]],
                            uint3 gid [[thread_position_in_grid]]) {
        uint tile = tiles[gid.z];
        uint2 px = uint2((tile % g.tilesX) * g.tilePixels + gid.x, (tile / g.tilesX) * g.tilePixels + gid.y);
        if (px.x >= g.width || px.y >= g.height) return;
        constexpr sampler point(filter::nearest, address::clamp_to_edge);
        float2 uv = (float2(px) + 0.5) / float2(g.width, g.height);
        dst.write(float4(deband(src, uv, src.sample(point, uv).rgb, g.range), 1.0), px);
    }

    // Scaling up (stream smaller than panel): Catmull-Rom, 9 bilinear taps
    // Keeps text edges sharper than plain bilinear
    // 1:1 or smaller: one bilinear tap, texel centres stay exact
    // Derivatives undefined in divergent branches: callers test outside them
    static bool scalingUp(texture2d<float> tex, float2 uv) {
        return fwidth(uv.x * float(tex.get_width())) < 0.99;
    }

    // `lo`, `hi`: uv bounds kept by the taps, centres included
    static float4 catmullRom(texture2d<float> tex, float2 uv, float2 lo = 0.0, float2 hi = 1.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 pos = uv * size;
        float2 t1 = floor(pos - 0.5) + 0.5, f = pos - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 a = lo + 0.5 / size, b = hi - 0.5 / size;
        float2 p0 = clamp((t1 - 1.0) / size, a, b), p12 = clamp((t1 + w2 / w12) / size, a, b), p3 = clamp((t1 + 2.0) / size, a, b);
        return saturate(tex.sample(s, float2(p0.x, p0.y)) * (w0.x * w0.y)
                      + tex.sample(s, float2(p12.x, p0.y)) * (w12.x * w0.y)
                      + tex.sample(s, float2(p3.x, p0.y)) * (w3.x * w0.y)
                      + tex.sample(s, float2(p0.x, p12.y)) * (w0.x * w12.y)
                      + tex.sample(s, float2(p12.x, p12.y)) * (w12.x * w12.y)
                      + tex.sample(s, float2(p3.x, p12.y)) * (w3.x * w12.y)
                      + tex.sample(s, float2(p0.x, p3.y)) * (w0.x * w3.y)
                      + tex.sample(s, float2(p12.x, p3.y)) * (w12.x * w3.y)
                      + tex.sample(s, float2(p3.x, p3.y)) * (w3.x * w3.y));
    }

    static float3 picture(texture2d<float> tex, float2 uv, bool up, float2 lo = 0.0, float2 hi = 1.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return up ? catmullRom(tex, uv, lo, hi).rgb : tex.sample(s, uv).rgb;
    }

    // Power effect: each tile opens after a jittered centre-distance delay
    // Tiles grow from 60% with overshoot, brightening from black
    // Closing runs corners-in and shrinks tiles to black
    // active 0: the picture as sent
    struct Wave { float progress; float active; float closing; float tilePixels; float2 size; };
    // Share of the wave one tile takes
    // Remainder: start spread from first tile to last
    constant float kWaveTile = 0.32;

    // Returns the uv to sample; `k`: pixel brightness
    static float2 waveUV(float2 uv, constant Wave &w, thread float &k) {
        k = 1.0;
        if (w.active == 0.0) return uv;
        float2 px = uv * w.size;
        float2 t = floor(px / w.tilePixels);
        float2 c = (t + 0.5) / ceil(w.size / w.tilePixels) - 0.5;
        float aspect = w.size.x / w.size.y;
        float d = length(float2(c.x * aspect, c.y)) / length(float2(0.5 * aspect, 0.5));
        d = saturate(d * 0.92 + hash01(uint2(t), 7u) * 0.08);
        if (w.closing > 0.0) d = 1.0 - d;
        float local = saturate((w.progress - d * (1.0 - kWaveTile)) / kWaveTile);
        float open = w.closing > 0.0 ? 1.0 - local : local;
        if (open <= 0.0) { k = 0.0; return uv; }
        // Ease-out-back for the size, ease-out for the light
        float x = open - 1.0;
        float scale = mix(0.6, 1.0, 1.0 + 2.2 * x * x * x + 1.2 * x * x);
        k = 1.0 - x * x;
        float2 s = (px / w.tilePixels - t - 0.5) / scale + 0.5;
        if (any(s < 0.0) || any(s > 1.0)) { k = 0.0; return uv; }
        return (t + s) * w.tilePixels / w.size;
    }

    // BC7 picture or its debanded copy; alpha not streamed
    fragment float4 tileFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Wave &w [[buffer(2)]]) {
        bool up = scalingUp(tex, in.uv);
        float k;
        float2 uv = waveUV(in.uv, w, k);
        if (k <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
        return float4(picture(tex, uv, up) * k, 1.0);
    }

    // grid: tiles per row, tile edge px, stream width, height
    static bool videoTile(device const uchar *mask, constant uint4 &grid, int2 t) {
        int rows = int((grid.w + grid.y - 1) / grid.y);
        return t.x >= 0 && t.y >= 0 && t.x < int(grid.x) && t.y < rows && mask[t.y * int(grid.x) + t.x] != 0;
    }

    // Uv bounds for scaling a BC7 tile up
    // Video neighbours hold stale BC7 texels: stop at that side
    // Only pixels within 2 texels of an edge look
    static void bc7Bounds(device const uchar *mask, constant uint4 &grid, uint2 p, float2 uv, thread float2 &lo, thread float2 &hi) {
        int2 t = int2(p / grid.y);
        float edge = float(grid.y);
        float2 size = float2(grid.zw), inTile = uv * size - float2(t) * edge;
        bool l = inTile.x < 2.0, r = inTile.x > edge - 2.0, u = inTile.y < 2.0, d = inTile.y > edge - 2.0;
        if (!(l || r || u || d)) return;
        bool v[3][3];
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) v[dy + 1][dx + 1] = videoTile(mask, grid, t + int2(dx, dy));
        float2 tileLo = float2(t) * edge / size, tileHi = min(float2(t + 1) * edge / size, 1.0);
        // Diagonals count only for pixels near that corner
        if (l && (v[1][0] || (u && v[0][0]) || (d && v[2][0]))) lo.x = tileLo.x;
        if (r && (v[1][2] || (u && v[0][2]) || (d && v[2][2]))) hi.x = tileHi.x;
        if (u && (v[0][1] || (l && v[0][0]) || (r && v[0][2]))) lo.y = tileLo.y;
        if (d && (v[2][1] || (l && v[2][0]) || (r && v[2][2]))) hi.y = tileHi.y;
    }

    // Masked tiles show video (NV12, BT.709 video range); others BC7
    fragment float4 hybridFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                   texture2d<float> luma [[texture(1)]], texture2d<float> chroma [[texture(2)]],
                                   device const uchar *mask [[buffer(0)]], constant uint4 &grid [[buffer(1)]],
                                   constant Wave &w [[buffer(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        bool up = scalingUp(tex, in.uv), videoUp = scalingUp(luma, in.uv);
        float k;
        float2 uv = waveUV(in.uv, w, k);
        if (k <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
        uint2 p = min(uint2(uv * float2(grid.zw)), grid.zw - uint2(1));
        if (mask[(p.y / grid.y) * grid.x + p.x / grid.y] == 0) {
            float2 lo = 0.0, hi = 1.0;
            if (up) bc7Bounds(mask, grid, p, uv, lo, hi);
            return float4(picture(tex, uv, up, lo, hi) * k, 1.0);
        }
        // Luma carries the detail: Catmull-Rom when scaled up
        // Half-resolution chroma stays bilinear
        float y = ((videoUp ? catmullRom(luma, uv).r : luma.sample(s, uv).r) - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
        return float4(saturate(rgb) * k, 1.0);
    }
    """

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: StreamRenderer.shaders, options: nil) else { return nil }
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "screenQuad")
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = StreamRenderer.drawableFormat
            return try? device.makeRenderPipelineState(descriptor: desc)
        }
        guard let tile = pipeline("tileFragment"), let hybrid = pipeline("hybridFragment") else { return nil }
        self.device = device
        self.queue = queue
        tilePipeline = tile
        hybridPipeline = hybrid
        tileTexture = TileTexture(device: device)
        debandCache = DebandCache(device: device, library: library)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        layer.device = device
        layer.pixelFormat = StreamRenderer.drawableFormat
        layer.framebufferOnly = true
        // Opaque full-screen layers allow direct scan-out on Apple silicon
        layer.isOpaque = true
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Main thread: keeps the drawable in step with the view
    /// `topInset`: points beside a camera notch, left black
    func layout(bounds: CGRect, scale: CGFloat, topInset: CGFloat = 0) {
        layer.frame = bounds
        layer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer.drawableSize = size
        sizeLock.lock()
        drawableSize = size
        insetPixels = min(size.height, topInset * scale)
        sizeLock.unlock()
    }

    /// Any queue: saves the next draw under /tmp/afterscreen-receiver-<time>
    /// `.png` the picture, `-screen.png` as shown
    func requestSnapshot() {
        sizeLock.lock()
        snapshotRequested = true
        sizeLock.unlock()
    }

    /// Any queue
    func setVisible(_ visible: Bool) {
        sizeLock.lock()
        isVisible = visible
        sizeLock.unlock()
    }

    /// Decode queue: redraws the current picture
    /// For a window shown again or a running effect
    /// Skipped if the stream drew within a few milliseconds
    func redraw() {
        statsLock.lock()
        let recent = CACurrentMediaTime() - lastDraw < 0.008
        statsLock.unlock()
        guard !recent, let g = lastGeometry, let cb = queue.makeCommandBuffer() else { return }
        encodePicture(cb, geometry: g)
    }

    /// Any queue: applies from the next draw
    func setWave(_ wave: Wave?) {
        sizeLock.lock()
        self.wave = wave
        sizeLock.unlock()
    }

    /// Decode queue, before `releaseResources`
    /// Keeps the picture at stream size for a closing wave
    func keepFarewell() {
        guard let g = lastGeometry, let cb = queue.makeCommandBuffer(), let bind = pictureBind(cb, geometry: g) else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: StreamRenderer.drawableFormat, width: g.width, height: g.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc) else { return cb.commit() }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return cb.commit() }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(g.width), height: Double(g.height), znear: 0, zfar: 1))
        bind(enc)
        var still = Wave.still
        enc.setFragmentBytes(&still, length: MemoryLayout<Wave.Parameters>.stride, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        sizeLock.lock()
        farewell = (target, g.tilePixels)
        sizeLock.unlock()
    }

    /// Any queue: the kept picture under the current wave
    func drawFarewell() {
        sizeLock.lock()
        let kept = farewell
        sizeLock.unlock()
        guard let kept = kept, let cb = queue.makeCommandBuffer() else { return }
        let content = CGSize(width: kept.texture.width, height: kept.texture.height)
        encodeDraw(cb, content: content, tilePixels: kept.tilePixels) { [tilePipeline] enc in
            enc.setRenderPipelineState(tilePipeline)
            enc.setFragmentTexture(kept.texture, index: 0)
        }
    }

    /// Any queue
    func dropFarewell() {
        sizeLock.lock()
        farewell = nil
        sizeLock.unlock()
    }

    /// Any queue: applies from the next draw
    func setDeband(_ level: Deband) {
        sizeLock.lock()
        debandRange = level.rangePixels
        sizeLock.unlock()
    }

    func reset() {
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil
        format = nil
        video = nil
        mask.reset()
        lastGeometry = nil
        statsLock.lock()
        stats = (0, 0, 0)
        statsLock.unlock()
    }

    func releaseResources() {
        reset()
        maskBuffers = []
        tileTexture.release()
        debandCache?.release()
    }

    // MARK: - Tile path

    /// false when the tile data fails to decode
    /// Without `present`, the upload commits undrawn
    func applyTiles(_ frame: TileFrame, present: Bool = true) -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }
        let start = ProcessInfo.processInfo.systemUptime
        tileTexture.ensure(geometry: frame.geometry)
        do {
            try tileTexture.encodeUpload(frame, into: cb)
        } catch {
            cb.commit()
            return false
        }
        let decode = tileTexture.lastDecodeMs
        statsLock.lock()
        stats.decodeMs = decode
        stats.uploadMs = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000 - decode)
        statsLock.unlock()
        mask.apply(frame.runs, geometry: frame.geometry)
        debandCache?.mark(frame.runs, geometry: frame.geometry)
        lastGeometry = frame.geometry
        sizeLock.lock()
        let visible = isVisible
        sizeLock.unlock()
        guard present, visible else {
            cb.commit()
            return true
        }
        encodePicture(cb, geometry: frame.geometry)
        return true
    }

    /// Draws the tile picture plus masked video; commits `cb`
    private func encodePicture(_ cb: MTLCommandBuffer, geometry g: TileGeometry) {
        guard let bind = pictureBind(cb, geometry: g) else { return cb.commit() }
        encodeDraw(cb, content: CGSize(width: g.width, height: g.height), tilePixels: g.tilePixels, bind: bind)
    }

    /// Pipeline and inputs for the current picture
    /// Encodes a due deband pass into `cb` first
    private func pictureBind(_ cb: MTLCommandBuffer, geometry g: TileGeometry) -> ((MTLRenderCommandEncoder) -> Void)? {
        guard let texture = tileTexture.texture else { return nil }
        sizeLock.lock()
        let range = debandRange
        sizeLock.unlock()
        let image = debandCache?.update(source: texture, geometry: g, range: range, into: cb) ?? texture
        if mask.shown > 0, let picture = video, let luma = CVMetalTextureGetTexture(picture.luma),
           let chroma = CVMetalTextureGetTexture(picture.chroma), let maskBuffer = nextMaskBuffer() {
            cb.addCompletedHandler { _ in _ = picture }
            let grid = [UInt32(g.tilesX), UInt32(g.tilePixels), UInt32(g.width), UInt32(g.height)]
            return { [hybridPipeline] enc in
                var grid = grid
                enc.setRenderPipelineState(hybridPipeline)
                enc.setFragmentTexture(image, index: 0)
                enc.setFragmentTexture(luma, index: 1)
                enc.setFragmentTexture(chroma, index: 2)
                enc.setFragmentBuffer(maskBuffer, offset: 0, index: 0)
                enc.setFragmentBytes(&grid, length: 16, index: 1)
            }
        }
        return { [tilePipeline] enc in
            enc.setRenderPipelineState(tilePipeline)
            enc.setFragmentTexture(image, index: 0)
        }
    }

    /// The current mask in the next ring buffer
    private func nextMaskBuffer() -> MTLBuffer? {
        let bytes = mask.bytes
        if maskBuffers.first.map({ $0.length != bytes.count }) ?? true {
            maskBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: bytes.count, options: .storageModeShared) }
        }
        guard maskBuffers.count == 3 else { return nil }
        maskRing = (maskRing + 1) % 3
        let buffer = maskBuffers[maskRing]
        bytes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return buffer
    }

    // MARK: - Video layer

    func setVideoParams(codec: VideoCodec, tenBit: Bool, parameterSets: [Data]) -> Bool {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = withPointers(parameterSets) { pointers, sizes in
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let newFormat = desc else { return false }
        if let current = format, CMFormatDescriptionEqual(current, otherFormatDescription: newFormat), decoder != nil, tenBit == self.tenBit { return true }
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &session)
        guard created == noErr, let s = session else { return false }
        decoder = s
        format = newFormat
        self.tenBit = tenBit
        return true
    }

    /// Decodes synchronously into the current video picture
    /// The next tile frame draws it
    func decodeVideo(avcc: Data) -> Bool {
        guard let decoder = decoder, let format = format, let sample = makeSample(avcc, format: format) else { return false }
        var image: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { image = buffer }
        }
        guard status == noErr, let pixelBuffer = image, let cache = textureCache else { return false }
        var luma: CVMetalTexture?, chroma: CVMetalTexture?
        // 10-bit samples sit in the high bits: same normalized math
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, tenBit ? .r16Unorm : .r8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &luma)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, tenBit ? .rg16Unorm : .rg8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &chroma)
        guard let l = luma, let c = chroma else { return false }
        video = (l, c)
        return true
    }

    private func makeSample(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let b = block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: b, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    // MARK: - Draw

    private func encodeDraw(_ cb: MTLCommandBuffer, content: CGSize, tilePixels: Int, bind picture: @escaping (MTLRenderCommandEncoder) -> Void) {
        sizeLock.lock()
        let size = drawableSize, inset = insetPixels
        let current = wave
        sizeLock.unlock()
        var params = current?.parameters(at: CACurrentMediaTime(), tilePixels: tilePixels, size: content) ?? Wave.still
        if case .opening? = current, params.active == 0 {
            sizeLock.lock()
            if wave == current { wave = nil }
            sizeLock.unlock()
        }
        let bind = { (enc: MTLRenderCommandEncoder) in
            picture(enc)
            enc.setFragmentBytes(&params, length: MemoryLayout<Wave.Parameters>.stride, index: 2)
        }
        let meter = gpuMeter
        cb.addCompletedHandler { cb in meter.add(seconds: cb.gpuEndTime - cb.gpuStartTime) }
        guard size.width > 0, let drawable = layer.nextDrawable() else {
            statsLock.lock()
            stats.late += 1
            statsLock.unlock()
            cb.commit()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            cb.commit()
            return
        }
        // Viewport y runs down: the notch strip on top
        let rect = RenderGeometry.aspectFit(content: content, in: CGRect(x: 0, y: inset, width: size.width, height: size.height - inset))
        enc.setViewport(MTLViewport(originX: Double(rect.minX), originY: Double(rect.minY),
                                    width: Double(rect.width), height: Double(rect.height), znear: 0, zfar: 1))
        bind(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        sizeLock.lock()
        let snapshot = snapshotRequested
        snapshotRequested = false
        sizeLock.unlock()
        if snapshot { encodeSnapshot(cb, content: content, screen: size, picture: rect, videoTiles: mask.shown > 0 ? mask.bytes : [], bind: bind) }
        cb.present(drawable)
        statsLock.lock()
        lastDraw = CACurrentMediaTime()
        statsLock.unlock()
        let counter = displayed
        cb.addCompletedHandler { _ in counter.tick() }
        cb.commit()
    }
}

extension StreamRenderer {
    /// Same draw into textures, written once the GPU is done
    /// Stream size: the picture alone, for pixel checks
    /// Screen size: as shown, letterbox included
    /// `videoTiles`: hybrid mask, one byte per tile (1 = video)
    fileprivate func encodeSnapshot(_ cb: MTLCommandBuffer, content: CGSize, screen: CGSize, picture: CGRect, videoTiles: [UInt8],
                                    bind: (MTLRenderCommandEncoder) -> Void) {
        // Milliseconds: snapshots within one second stay apart
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let base = "/tmp/afterscreen-receiver-\(stamp)"
        encodeCapture(cb, size: content, picture: CGRect(origin: .zero, size: content), path: base + ".png", mask: videoTiles, bind: bind)
        encodeCapture(cb, size: screen, picture: picture, path: base + "-screen.png", mask: [], bind: bind)
    }

    /// `mask` saved next to the image when not empty
    private func encodeCapture(_ cb: MTLCommandBuffer, size: CGSize, picture: CGRect, path: String, mask: [UInt8],
                               bind: (MTLRenderCommandEncoder) -> Void) {
        let w = Int(size.width), h = Int(size.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: StreamRenderer.drawableFormat, width: w, height: h, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        guard w > 0, h > 0, let target = layer.device?.makeTexture(descriptor: desc),
              let buffer = layer.device?.makeBuffer(length: w * h * 4, options: .storageModeShared) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setViewport(MTLViewport(originX: Double(picture.minX), originY: Double(picture.minY),
                                    width: Double(picture.width), height: Double(picture.height), znear: 0, zfar: 1))
        bind(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            let words = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self), count: w * h))
            DispatchQueue.global(qos: .utility).async {
                let url = URL(fileURLWithPath: path)
                let result = (try? ScreenSnapshot.writePNG(words: words, width: w, height: h, to: url)) != nil ? url.path : "failed"
                if !mask.isEmpty { try? Data(mask).write(to: url.deletingPathExtension().appendingPathExtension("mask")) }
                FileHandle.standardError.write(Data("[receiver] Snapshot: \(result)\n".utf8))
            }
        }
    }
}

private func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
    let copies = sets.map { data -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
        data.copyBytes(to: p, count: data.count)
        return p
    }
    defer { copies.forEach { $0.deallocate() } }
    return body(copies.map { UnsafePointer($0) }, sets.map(\.count))
}
