import CoreMedia
import CoreVideo
import Metal
import AfterscreenCore
import QuartzCore
import VideoToolbox

/// Draws the current picture into a CAMetalLayer, letterboxed: the BC7 tile texture,
/// with the hybrid path's video picture in tiles the mask marks.
/// All entry points run on the session decode queue except `layout`
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
    private var textureCache: CVMetalTextureCache?
    private var decoder: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    /// Latest decoded video picture (NV12 planes); each draw that samples it keeps it alive
    private var video: (luma: CVMetalTexture, chroma: CVMetalTexture)?
    private var mask = VideoMask()
    /// Decoded planes are 16-bit (10 bits used) for a Main10 stream
    private var tenBit = false
    /// 10 bits per channel: the iMac panels take 10-bit input, so dithered BC7 and Main10 video keep their steps
    static let drawableFormat = MTLPixelFormat.bgr10a2Unorm
    /// Ring of 3: with 2 drawables, the draw that last read a buffer has completed before its reuse
    private var maskBuffers: [MTLBuffer] = []
    private var maskRing = 0
    private let sizeLock = NSLock()
    private var drawableSize = CGSize.zero

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

    // BC7 picture; alpha is not part of the stream
    fragment float4 tileFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }

    // grid: tiles per row, tile edge in pixels, stream width and height.
    // Masked tiles show the video picture (NV12, BT.709 video range), the rest the BC7 picture
    fragment float4 hybridFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                   texture2d<float> luma [[texture(1)]], texture2d<float> chroma [[texture(2)]],
                                   device const uchar *mask [[buffer(0)]], constant uint4 &grid [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        uint2 p = min(uint2(in.uv * float2(grid.zw)), grid.zw - uint2(1));
        if (mask[(p.y / grid.y) * grid.x + p.x / grid.y] == 0) return float4(tex.sample(s, in.uv).rgb, 1.0);
        float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
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
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        layer.device = device
        layer.pixelFormat = StreamRenderer.drawableFormat
        layer.framebufferOnly = true
        // Opaque full-screen layers can be scanned out directly on Apple-silicon receivers
        layer.isOpaque = true
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Main thread: keeps the drawable in step with the view
    func layout(bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        layer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer.drawableSize = size
        sizeLock.lock()
        drawableSize = size
        sizeLock.unlock()
    }

    func reset() {
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil
        format = nil
        video = nil
        mask.reset()
        statsLock.lock()
        stats = (0, 0, 0)
        statsLock.unlock()
    }

    func releaseResources() {
        reset()
        maskBuffers = []
        tileTexture.release()
    }

    // MARK: - Tile path

    /// false when the tile data fails to decode; without `present` the upload commits undrawn
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
        guard present, let texture = tileTexture.texture else {
            cb.commit()
            return true
        }
        let g = frame.geometry
        let content = CGSize(width: g.width, height: g.height)
        if mask.shown > 0, let picture = video, let luma = CVMetalTextureGetTexture(picture.luma),
           let chroma = CVMetalTextureGetTexture(picture.chroma), let maskBuffer = nextMaskBuffer() {
            cb.addCompletedHandler { _ in _ = picture }
            var grid = [UInt32(g.tilesX), UInt32(g.tilePixels), UInt32(g.width), UInt32(g.height)]
            encodeDraw(cb, content: content) { enc in
                enc.setRenderPipelineState(hybridPipeline)
                enc.setFragmentTexture(texture, index: 0)
                enc.setFragmentTexture(luma, index: 1)
                enc.setFragmentTexture(chroma, index: 2)
                enc.setFragmentBuffer(maskBuffer, offset: 0, index: 0)
                enc.setFragmentBytes(&grid, length: 16, index: 1)
            }
        } else {
            encodeDraw(cb, content: content) { enc in
                enc.setRenderPipelineState(tilePipeline)
                enc.setFragmentTexture(texture, index: 0)
            }
        }
        return true
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

    /// Decodes synchronously into the current video picture; the next tile frame draws it
    func decodeVideo(avcc: Data) -> Bool {
        guard let decoder = decoder, let format = format, let sample = makeSample(avcc, format: format) else { return false }
        var image: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { image = buffer }
        }
        guard status == noErr, let pixelBuffer = image, let cache = textureCache else { return false }
        var luma: CVMetalTexture?, chroma: CVMetalTexture?
        // 10-bit planes hold their samples in the high bits of 16, so the same normalized math applies
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

    private func encodeDraw(_ cb: MTLCommandBuffer, content: CGSize, bind: (MTLRenderCommandEncoder) -> Void) {
        sizeLock.lock()
        let size = drawableSize
        sizeLock.unlock()
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
        let rect = RenderGeometry.aspectFit(content: content, in: CGRect(origin: .zero, size: size))
        enc.setViewport(MTLViewport(originX: Double(rect.minX), originY: Double(rect.minY),
                                    width: Double(rect.width), height: Double(rect.height), znear: 0, zfar: 1))
        bind(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        let counter = displayed
        cb.addCompletedHandler { _ in counter.tick() }
        cb.commit()
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
