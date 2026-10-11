import AppKit
import CoreText
import CoreVideo
import Metal
import AfterscreenCore

/// Test frames: aurora backdrop, frame ladder, moving card,
/// scrolling document and a video window
/// Full motion changes every tile every frame
/// Typical use moves the video, the document and the ladder
final class TestPattern {
    enum Motion { case full, typical }

    /// Per stage: caption, refresh, what moves
    struct Stage: Equatable {
        var caption: String
        var frameRate: Double
        var motion: Motion
    }

    /// `Params` in the shader; same field order
    private struct Params {
        var ladder: SIMD4<Float>
        var card: SIMD4<Float>
        var doc: SIMD4<Float>
        var video: SIMD4<Float>
        var size: SIMD2<Float>
        var caption: SIMD2<Float>
        var counter: SIMD2<Float>
        var digit: SIMD2<Float>
        var h: Float
        var time: Float
        var videoTime: Float
        var radius: Float
        var docScroll: Float
        var bar: Float
        var frame: UInt32
        var cells: UInt32
        var seed: UInt32
        var docHeight: UInt32
    }

    /// Pixel rects, sized from the height
    private struct Layout {
        let width: Int, height: Int
        let margin: Int
        let caption: CGPoint
        let ladder: CGRect
        let card: CGRect
        let doc: CGRect
        let video: CGRect
        let radius: Int
        let bar: Int
        /// Size unit: the height; less below 16:10
        let unit: Double

        init(_ size: PixelSize) {
            let u = min(Double(size.height), Double(size.width) / 1.6)
            unit = u
            func r(_ v: Double) -> Int { Int((v * u).rounded()) }
            width = size.width
            height = size.height
            margin = r(0.05)
            caption = CGPoint(x: margin, y: r(0.042))
            ladder = CGRect(x: margin, y: r(0.094), width: size.width - 2 * margin, height: r(0.014))
            card = CGRect(x: margin, y: r(0.160), width: r(0.74), height: r(0.30))
            let panelY = r(0.52), panelH = r(0.43)
            let videoW = Int(Double(panelH) * 16 / 9)
            video = CGRect(x: size.width - margin - videoW, y: panelY, width: videoW, height: panelH)
            let docW = min(r(0.80), Int(video.minX) - r(0.06) - margin)
            doc = CGRect(x: margin, y: panelY, width: max(docW, r(0.3)), height: panelH)
            radius = r(0.016)
            bar = r(0.030)
        }
    }

    /// Text drawn once per size, caption and motion
    private struct Layers {
        let size: PixelSize
        let caption: String
        let moving: Bool
        let layout: Layout
        let card: MTLTexture
        let doc: MTLTexture
        let captionTexture: MTLTexture
        let digits: MTLTexture
        let digitSize: CGSize
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float4 ladder;
        float4 card;
        float4 doc;
        float4 video;
        float2 size;
        float2 caption;
        float2 counter;
        float2 digit;
        float h;
        float time;
        float videoTime;
        float radius;
        float docScroll;
        float bar;
        uint frame;
        uint cells;
        uint seed;
        uint docHeight;
    };

    static uint ihash(uint x) {
        x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
        return x;
    }
    static float hashf(float n) { return float(ihash(uint(int(n) + 1048576))) * (1.0 / 4294967296.0); }
    static float hashf2(float2 p) {
        return float(ihash(uint(int(p.x) + 1048576) ^ ihash(uint(int(p.y) + 3145728)))) * (1.0 / 4294967296.0);
    }
    static float noise1(float x) {
        float i = floor(x), f = fract(x), u = f * f * (3.0 - 2.0 * f);
        return mix(hashf(i), hashf(i + 1.0), u);
    }
    static float noise2(float2 p) {
        float2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
        float a = hashf2(i), b = hashf2(i + float2(1, 0)), c = hashf2(i + float2(0, 1)), d = hashf2(i + float2(1, 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    static float fbm1(float x) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise1(x); x = x * 2.1 + 7.3; a *= 0.5; }
        return v;
    }
    static float fbm2(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) { v += a * noise2(p); p = p * 2.03 + float2(17.1, 9.2); a *= 0.5; }
        return v;
    }
    static float roundRect(float2 p, float4 r, float radius) {
        float2 hs = r.zw * 0.5;
        float2 q = abs(p - (r.xy + hs)) - hs + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }
    static float3 over(float3 dst, float4 src) { return src.rgb + dst * (1.0 - src.a); }

    // Three bands: bright lower edge, exponential fade upward
    // Green at the edge, violet above
    // Ray noise follows the fold
    static float3 aurora(float2 p, float t) {
        float3 col = mix(float3(0.008, 0.010, 0.030), float3(0.050, 0.036, 0.125), smoothstep(0.1, 1.0, p.y));
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float fold = sin(p.x * (1.5 + 0.4 * fi) + t * (0.10 + 0.03 * fi) + fi * 2.3);
            float edge = 0.30 + 0.07 * fi + 0.085 * fold
                       + 0.030 * sin(p.x * (3.1 - 0.5 * fi) - t * (0.06 + 0.02 * fi) + fi * 1.1)
                       + 0.010 * sin(p.x * 7.3 + t * 0.35 + fi * 5.0);
            float d = edge - p.y;
            float body = exp(-max(d, 0.0) / (0.20 - 0.04 * fi)) * smoothstep(-0.035, 0.012, d);
            float ray = noise1(p.x * 34.0 + fold * 6.0 + fi * 31.0 + t * 0.25);
            float rays = 0.35 + 0.9 * ray * ray;
            float sway = 0.65 + 0.35 * sin(p.x * 0.9 - t * 0.17 + fi * 2.0);
            float3 low = i == 1 ? float3(0.20, 0.72, 1.00) : float3(0.16, 0.95, 0.66);
            float3 high = i == 2 ? float3(0.82, 0.28, 0.86) : float3(0.40, 0.30, 0.98);
            col += mix(low, high, saturate(d / 0.26)) * body * rays * sway * (0.30 - 0.07 * fi);
        }
        return col;
    }

    static float3 stars(float2 p, float t) {
        float2 g = p * 160.0;
        float r = hashf2(floor(g));
        if (r < 0.986) return float3(0.0);
        float s = smoothstep(0.16, 0.0, length(fract(g) - 0.5));
        return float3(s * (0.35 + 0.25 * sin(t * 0.7 + r * 50.0)) * smoothstep(0.55, 0.1, p.y));
    }

    // Sky gradient, sun, fbm clouds, three parallax ridges
    static float3 scene(float2 q, float t, float width, float px) {
        float3 col = q.y < 0.42 ? mix(float3(0.09, 0.09, 0.30), float3(0.58, 0.30, 0.55), q.y / 0.42)
                                : mix(float3(0.58, 0.30, 0.55), float3(1.00, 0.63, 0.40), saturate((q.y - 0.42) / 0.22));
        float sd = length(q - float2(width * 0.70, 0.50));
        col += float3(1.0, 0.80, 0.55) * smoothstep(0.050 + px, 0.050 - px, sd) * 0.9;
        col += float3(1.0, 0.55, 0.35) * exp(-sd * 6.0) * 0.30;
        if (q.y < 0.62) {
            float cloud = fbm2(float2(q.x * 2.4 + t * 0.04, q.y * 7.0 - t * 0.01));
            float cm = smoothstep(0.52, 0.78, cloud) * smoothstep(0.62, 0.12, q.y);
            col = mix(col, mix(float3(1.0, 0.72, 0.62), float3(0.38, 0.26, 0.50), saturate(q.y * 1.6)), cm * 0.55);
        }
        float3 tint[3] = { float3(0.62, 0.38, 0.55), float3(0.26, 0.16, 0.36), float3(0.07, 0.05, 0.13) };
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float ridge = 0.58 + 0.10 * fi - (0.16 - 0.03 * fi) * fbm1(q.x * (1.4 + 1.3 * fi) + t * (0.05 + 0.09 * fi) + fi * 11.0);
            float cover = smoothstep(ridge - px, ridge + px, q.y);
            if (cover <= 0.0) continue;
            float3 layer = tint[i] + float3(1.0, 0.6, 0.4) * exp(-(q.y - ridge) * 18.0) * (0.10 - 0.03 * fi);
            layer *= 0.82 + 0.36 * fbm2(float2(q.x * (6.0 + 6.0 * fi) + t * (0.3 + 0.55 * fi), q.y * (9.0 + 8.0 * fi)));
            col = mix(col, layer, cover);
        }
        return col;
    }

    static float3 chrome(float3 bg, float2 px, float4 r, float bar) {
        float3 c = bg * 0.18 + float3(0.075, 0.080, 0.112);
        for (int k = 0; k < 3; k++) {
            float2 dot = float2(r.x + bar * (0.62 + 0.55 * float(k)), r.y + bar * 0.5);
            c = mix(c, float3(0.32, 0.34, 0.42), saturate(bar * 0.17 + 0.5 - length(px - dot)));
        }
        return c;
    }

    static float3 rim(float3 c, float d, float tt) {
        return c + float3(0.16) * saturate(1.0 - abs(d + 0.75) / 0.9) * (1.0 - 0.6 * tt);
    }

    // Backdrop at a quarter of the size: smooth enough to scale
    kernel void skyPass(texture2d<float, access::write> out [[texture(0)]],
                        constant Params &P [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 k = P.size / float2(out.get_width(), out.get_height());
        out.write(float4(aurora((float2(gid) + 0.5) * k / P.h, P.time), 1.0), gid);
    }

    kernel void testPattern(texture2d<float, access::write> out [[texture(0)]],
                            texture2d<float, access::read> card [[texture(1)]],
                            texture2d<float, access::read> doc [[texture(2)]],
                            texture2d<float, access::read> caption [[texture(3)]],
                            texture2d<float, access::read> digits [[texture(4)]],
                            texture2d<float, access::sample> backdrop [[texture(5)]],
                            constant Params &P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
        if (gid.x >= uint(P.size.x) || gid.y >= uint(P.size.y)) return;
        float2 px = float2(gid) + 0.5;
        float h = P.h;
        // Video body: opaque, nothing else reaches it
        float dv = roundRect(px, P.video, P.radius);
        float videoTop = P.video.y + P.bar, videoH = P.video.w - P.bar;
        float grain = (float(ihash(gid.x * 7919u + gid.y * 104729u + P.seed * 15485863u) & 255u) / 255.0 - 0.5) * (2.5 / 255.0);
        float videoGrain = (float(ihash(gid.x * 1973u + gid.y * 9277u + P.frame * 26699u) & 255u) / 255.0 - 0.5) * (3.0 / 255.0);
        if (dv < -2.0 && px.y >= videoTop + 1.0) {
            float3 v = scene(float2(px.x - P.video.x, px.y - videoTop) / videoH, P.videoTime, P.video.z / videoH, 1.0 / videoH);
            out.write(float4(saturate(v + videoGrain + grain), 1.0), gid);
            return;
        }

        // Panes tint from bg, without stars
        float3 bg = backdrop.sample(bilinear, px / P.size).rgb;
        float3 col = bg + stars(px / h, P.time);

        // Frame ladder: one cell per frame, fading trail
        if (px.y >= P.ladder.y && px.y < P.ladder.y + P.ladder.w && px.x >= P.ladder.x && px.x < P.ladder.x + P.ladder.z) {
            float slot = P.ladder.z / float(P.cells);
            uint i = min(uint((px.x - P.ladder.x) / slot), P.cells - 1);
            float4 cell = float4(P.ladder.x + float(i) * slot + slot * 0.14, P.ladder.y, slot * 0.72, P.ladder.w);
            float d = roundRect(px, cell, min(cell.z, cell.w) * 0.35);
            uint age = (P.frame % P.cells + P.cells - i) % P.cells;
            float lit = age == 0 ? 1.0 : (age < 12 ? 0.5 * exp(-float(age) / 3.0) : 0.0);
            float3 c = mix(float3(0.55, 0.60, 0.75), float3(0.82, 1.0, 0.94), lit);
            col = mix(col, c, saturate(0.5 - d) * (0.14 + 0.86 * lit));
        }
        float2 cp = px - P.caption;
        if (cp.x >= 0.0 && cp.y >= 0.0 && cp.x < float(caption.get_width()) && cp.y < float(caption.get_height()))
            col = over(col, caption.read(uint2(cp)));
        float2 dp = px - P.counter;
        if (dp.x >= 0.0 && dp.y >= 0.0 && dp.x < P.digit.x * 6.0 && dp.y < P.digit.y) {
            uint place = uint(dp.x / P.digit.x);
            uint value = P.frame;
            for (uint k = place; k < 5; k++) value /= 10;
            uint2 at = uint2(uint(float(value % 10) * P.digit.x + fmod(dp.x, P.digit.x)), uint(dp.y));
            col = over(col, digits.read(at));
        }

        // Moving card: glass over a soft shadow
        float dc = roundRect(px, P.card, P.radius);
        float ds = roundRect(px - float2(0.0, h * 0.010), P.card, P.radius);
        col *= 1.0 - 0.5 * exp(-max(ds, 0.0) / (h * 0.022));
        if (dc < 1.0) {
            float tt = saturate((px.y - P.card.y) / P.card.w);
            float3 glass = rim(bg * 0.45 + float3(0.090, 0.095, 0.140) + float3(0.05) * (1.0 - tt), dc, tt);
            int2 at = int2(floor(px - P.card.xy));
            if (at.x >= 0 && at.y >= 0 && at.x < int(card.get_width()) && at.y < int(card.get_height()))
                glass = over(glass, card.read(uint2(at)));
            col = mix(col, glass, saturate(0.5 - dc));
        }

        // Document window: text scrolls under a fixed title bar
        float dd = roundRect(px, P.doc, P.radius);
        col *= 1.0 - 0.45 * exp(-max(roundRect(px - float2(0.0, h * 0.008), P.doc, P.radius), 0.0) / (h * 0.02));
        if (dd < 1.0) {
            float top = P.doc.y + P.bar;
            float3 pane;
            if (px.y < top) {
                pane = chrome(bg, px, P.doc, P.bar);
            } else {
                pane = bg * 0.18 + float3(0.040, 0.045, 0.068);
                float2 tp = float2(px.x - P.doc.x, px.y - top + P.docScroll);
                if (tp.x < float(doc.get_width())) {
                    float fade = smoothstep(0.0, h * 0.03, px.y - top) * smoothstep(0.0, h * 0.03, P.doc.y + P.doc.w - px.y);
                    pane = over(pane, doc.read(uint2(uint(tp.x), uint(tp.y) % P.docHeight)) * fade);
                }
            }
            col = mix(col, rim(pane, dd, 0.0), saturate(0.5 - dd));
        }

        // Video window edge and title bar; grain changes every frame
        col *= 1.0 - 0.45 * exp(-max(roundRect(px - float2(0.0, h * 0.008), P.video, P.radius), 0.0) / (h * 0.02));
        if (dv < 1.0) {
            float3 pane = px.y < videoTop ? chrome(bg, px, P.video, P.bar)
                : scene(float2(px.x - P.video.x, px.y - videoTop) / videoH, P.videoTime, P.video.z / videoH, 1.0 / videoH) + videoGrain;
            col = mix(col, rim(pane, dv, 0.0), saturate(0.5 - dv));
        }

        // Grain: per frame in full motion, fixed otherwise
        out.write(float4(saturate(col + grain), 1.0), gid);
    }
    """

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let skyPipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var pool: (size: PixelSize, pool: CVPixelBufferPool)?
    private var cached: Layers?
    /// Backdrop and the time it shows; still in typical use
    private var sky: (size: PixelSize, time: Float, texture: MTLTexture)?

    init?() {
        var cache: CVMetalTextureCache?
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: TestPattern.source, options: nil),
              let picture = library.makeFunction(name: "testPattern"), let backdrop = library.makeFunction(name: "skyPass"),
              let pipeline = try? device.makeComputePipelineState(function: picture),
              let skyPipeline = try? device.makeComputePipelineState(function: backdrop),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.skyPipeline = skyPipeline
        self.cache = textureCache
    }

    /// nil while 4 such frames are still in use downstream
    func frame(size: PixelSize, index: Int, stage: Stage) -> CVPixelBuffer? {
        guard let layers = layers(size: size, caption: stage.caption, moving: stage.motion == .full) else { return nil }
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
        guard let texture = cvTexture.flatMap(CVMetalTextureGetTexture), let backdrop = skyTexture(size), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        var params = parameters(layers, index: index, stage: stage)
        if sky?.time != params.time {
            enc.setComputePipelineState(skyPipeline)
            enc.setTexture(backdrop, index: 0)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: (backdrop.width + 15) / 16, height: (backdrop.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            sky?.time = params.time
        }
        enc.setComputePipelineState(pipeline)
        enc.setTextures([texture, layers.card, layers.doc, layers.captionTexture, layers.digits, backdrop], range: 0..<6)
        enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (size.width + 15) / 16, height: (size.height + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return buffer
    }

    /// Quarter size; a new one draws on first use
    private func skyTexture(_ size: PixelSize) -> MTLTexture? {
        if let s = sky, s.size == size { return s.texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: (size.width + 3) / 4,
                                                         height: (size.height + 3) / 4, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        sky = (size, .nan, t)
        return t
    }

    /// Regions typical use changes; nil: every tile
    /// Capture's dirty rects play this part in a session
    func changing(size: PixelSize, stage: Stage) -> [CGRect]? {
        guard stage.motion == .typical, let layers = layers(size: size, caption: stage.caption, moving: false) else { return nil }
        let l = layers.layout
        let counter = CGRect(x: l.caption.x + CGFloat(layers.captionTexture.width), y: l.caption.y,
                             width: layers.digitSize.width * 6, height: layers.digitSize.height)
        return [counter, l.ladder, l.doc, l.video].map { $0.insetBy(dx: -2, dy: -2) }
    }

    /// Steps per frame: a lost frame shows as a jump
    private func parameters(_ layers: Layers, index: Int, stage: Stage) -> Params {
        let l = layers.layout, u = l.unit, fps = max(1, stage.frameRate)
        let full = stage.motion == .full
        let time = Double(index) / fps
        let cardStep = max(1, Int((0.35 * u / fps).rounded()))
        let travel = l.width + Int(l.card.width)
        let cardX = full ? (index * cardStep) % travel - Int(l.card.width) : l.margin
        let scrollStep = max(1, Int((0.12 * u / fps).rounded()))
        let docHeight = layers.doc.height
        func rect(_ r: CGRect, x: Int? = nil) -> SIMD4<Float> {
            SIMD4(Float(x ?? Int(r.minX)), Float(r.minY), Float(r.width), Float(r.height))
        }
        let digitW = Float(layers.digitSize.width)
        return Params(ladder: rect(l.ladder), card: rect(l.card, x: cardX), doc: rect(l.doc), video: rect(l.video),
                      size: SIMD2(Float(l.width), Float(l.height)),
                      caption: SIMD2(Float(l.caption.x), Float(l.caption.y)),
                      counter: SIMD2(Float(l.caption.x) + Float(layers.captionTexture.width), Float(l.caption.y)),
                      digit: SIMD2(digitW, Float(layers.digitSize.height)),
                      h: Float(u), time: full ? Float(time) : 0, videoTime: Float(time), radius: Float(l.radius),
                      docScroll: Float((index * scrollStep) % docHeight), bar: Float(l.bar),
                      frame: UInt32(index % 1_000_000), cells: UInt32(max(1, Int(fps.rounded()))),
                      seed: full ? UInt32(truncatingIfNeeded: index) : 0, docHeight: UInt32(docHeight))
    }

    // MARK: - Text layers

    private func layers(size: PixelSize, caption: String, moving: Bool) -> Layers? {
        if let l = cached, l.size == size, l.caption == caption, l.moving == moving { return l }
        let layout = Layout(size)
        let u = CGFloat(layout.unit)
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 0.022 * u, weight: .medium)
        let digitW = ceil("0123456789".map { TestPattern.line(String($0), font: digitFont, color: .white).width }.max() ?? 1)
        let digitH = ceil(0.034 * u)
        let captionFont = NSFont.systemFont(ofSize: 0.022 * u, weight: .medium)
        // Frame counter follows: top right is under the receiver's HUD
        let captionLine = TestPattern.line(caption + "  ·  ", font: captionFont, color: CGColor(gray: 1, alpha: 0.92))
        guard let card = cardTexture(layout, moving: moving),
              let doc = docTexture(layout),
              let captionTexture = texture(width: Int(ceil(captionLine.width)) + 2, height: Int(digitH), draw: { c, height in
                  TestPattern.draw(captionLine.line, x: 0, baseline: 0.025 * u, height: height, in: c)
              }),
              let digits = texture(width: Int(digitW) * 10, height: Int(digitH), draw: { c, height in
                  for d in 0..<10 {
                      let l = TestPattern.line(String(d), font: digitFont, color: CGColor(gray: 1, alpha: 0.55))
                      TestPattern.draw(l.line, x: CGFloat(d) * digitW + (digitW - l.width) / 2, baseline: 0.025 * u, height: height, in: c)
                  }
              }) else { return nil }
        let made = Layers(size: size, caption: caption, moving: moving, layout: layout, card: card, doc: doc, captionTexture: captionTexture,
                          digits: digits, digitSize: CGSize(width: digitW, height: digitH))
        cached = made
        return made
    }

    /// Sizes, grey ramp and colour-on-colour text
    private func cardTexture(_ layout: Layout, moving: Bool) -> MTLTexture? {
        let u = CGFloat(layout.unit), w = layout.card.width, pad = 0.032 * u
        return texture(width: Int(w), height: Int(layout.card.height)) { c, height in
            let title = TestPattern.line("Afterscreen", font: .systemFont(ofSize: 0.034 * u, weight: .semibold), color: CGColor(gray: 1, alpha: 0.96))
            TestPattern.draw(title.line, x: pad, baseline: pad + 0.030 * u, height: height, in: c)
            let note = TestPattern.line(moving ? "Moving at a constant speed" : "Still: full quality", font: .systemFont(ofSize: 0.015 * u, weight: .regular), color: CGColor(gray: 1, alpha: 0.55))
            TestPattern.draw(note.line, x: w - pad - note.width, baseline: pad + 0.030 * u, height: height, in: c)

            var x = pad
            for s in [0.010, 0.014, 0.020, 0.030] {
                let l = TestPattern.line("Aa Bb Gg 0123", font: .systemFont(ofSize: CGFloat(s) * u, weight: .regular), color: CGColor(gray: 1, alpha: 0.92))
                TestPattern.draw(l.line, x: x, baseline: pad + 0.092 * u, height: height, in: c)
                x += l.width + 0.026 * u
            }

            let ramp = CGRect(x: pad, y: pad + 0.118 * u, width: w - 2 * pad, height: 0.026 * u)
            c.saveGState()
            c.addPath(CGPath(roundedRect: TestPattern.flip(ramp, height), cornerWidth: 0.006 * u, cornerHeight: 0.006 * u, transform: nil))
            c.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
            let r = TestPattern.flip(ramp, height)
            c.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
            c.restoreGState()

            let pills: [(String, CGColor, CGColor)] = [
                ("Red on blue", CGColor(srgbRed: 0.10, green: 0.25, blue: 0.95, alpha: 1), CGColor(srgbRed: 1.0, green: 0.22, blue: 0.22, alpha: 1)),
                ("Blue on red", CGColor(srgbRed: 0.90, green: 0.12, blue: 0.12, alpha: 1), CGColor(srgbRed: 0.15, green: 0.38, blue: 1.0, alpha: 1)),
                ("White on gray", CGColor(gray: 0.45, alpha: 1), CGColor(gray: 1, alpha: 1)),
            ]
            var px = pad
            let top = pad + 0.176 * u, pillH = 0.044 * u
            for (text, back, fore) in pills {
                let l = TestPattern.line(text, font: .systemFont(ofSize: 0.018 * u, weight: .semibold), color: fore)
                let pill = CGRect(x: px, y: top, width: l.width + 0.036 * u, height: pillH)
                c.setFillColor(back)
                c.addPath(CGPath(roundedRect: TestPattern.flip(pill, height), cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
                c.fillPath()
                TestPattern.draw(l.line, x: px + 0.018 * u, baseline: top + pillH * 0.66, height: height, in: c)
                px = pill.maxX + 0.016 * u
            }
        }
    }

    /// Guide text, one pass; the shader wraps it
    /// Height is the text plus one gap: the seam matches
    private func docTexture(_ layout: Layout) -> MTLTexture? {
        let u = CGFloat(layout.unit), w = layout.doc.width, pad = 0.030 * u
        let body = NSFont.systemFont(ofSize: 0.017 * u, weight: .regular)
        let head = NSFont.systemFont(ofSize: 0.021 * u, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0.012 * u
        let text = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ alpha: CGFloat) {
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: font, .paragraphStyle: style,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
            ]))
        }
        let section = [
            ("Quality test", true),
            ("The ladder at the top lights one cell per frame. A skipped cell is a frame that never reached the screen.", false),
            ("The card crosses at a constant speed. Uneven motion or smeared letters mean stutter or heavy compression.", false),
            ("This document scrolls at a constant speed. Small text should stay crisp while it moves.", false),
            ("The window on the right loads the link the way a playing video does.", false),
            ("Reading", true),
            ("The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow. 0123456789", false),
            ("Tone and color", true),
            ("The gray bar should run evenly from black to white. Blurred edges on the red and blue labels mean color detail was reduced.", false),
        ]
        for (s, h) in section { add(s, h ? head : body, h ? 0.95 : 0.80) }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let column = CGSize(width: w - 2 * pad, height: .greatestFiniteMagnitude)
        let textHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, column, nil).height)
        let gap = ceil(0.04 * u)
        return texture(width: Int(w), height: Int(textHeight + gap)) { c, h in
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: pad, y: gap, width: w - 2 * pad, height: textHeight), transform: nil), nil)
            CTFrameDraw(frame, c)
        }
    }

    private static func line(_ text: String, font: NSFont, color: CGColor) -> (line: CTLine, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// `baseline` from the top of a `height` tall bitmap
    private static func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, height: CGFloat, in c: CGContext) {
        c.textPosition = CGPoint(x: x, y: height - baseline)
        CTLineDraw(line, c)
    }

    /// Top-down rect to Core Graphics' bottom-up
    private static func flip(_ r: CGRect, _ height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// Premultiplied RGBA, drawn by `draw(context, height)`
    private func texture(width: Int, height: Int, draw: (CGContext, CGFloat) -> Void) -> MTLTexture? {
        guard width > 0, height > 0,
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        draw(c, CGFloat(height))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d), let data = c.data else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: c.bytesPerRow)
        return t
    }
}
