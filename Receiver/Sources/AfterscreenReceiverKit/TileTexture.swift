import Foundation
import Metal
import AfterscreenCore

/// Persistent BC7 picture; one blit per run, in GPU order.
/// Stored frames blit from the payload itself; compressed ones decode into staging first.
/// BC1 runs are transcoded to BC7 mode 6 on the GPU, so one texture and one shader serve both
public final class TileTexture {
    public private(set) var texture: MTLTexture?
    public private(set) var geometry: TileGeometry?
    /// CPU time of the last frame's decode into staging
    public private(set) var lastDecodeMs = 0.0

    private static let stagingCount = 2
    private let device: MTLDevice
    /// nil if the shader fails to compile; BC1 frames then fail to decode and end the session
    private let transcoder: MTLComputePipelineState?
    /// Transcoded BC1 runs, BC7-sized; allocated on first use
    private var transcoded: MTLBuffer?
    private var staging: [MTLBuffer] = []
    private var ring = 0
    /// Free staging buffers; starts at 0 and counts up (release below the initial value traps)
    private let free = DispatchSemaphore(value: 0)
    private let scratch: [UnsafeMutableRawPointer?]
    /// One Metal wrapper per pooled payload buffer, made once; dropped before the pool unmaps it
    private let wrapLock = NSLock()
    private var wraps: [UnsafeMutableRawPointer: MTLBuffer] = [:]
    private(set) var wrappedBuffers = 0

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    """ + BC7.metalCommon + """

    // BC1 index → mode 6 index: c0, c1, 21/64 and 43/64 of the way
    constant uchar kBC1Index[4] = {0, 15, 5, 10};

    kernel void bc1ToBC7(device const uint2 *src [[buffer(0)]],
                         device uint4 *dst [[buffer(1)]],
                         constant uint &count [[buffer(2)]],
                         uint i [[thread_position_in_grid]]) {
        if (i >= count) return;
        uint2 b = src[i];
        int3 e[2] = { unpack565(b.x & 0xFFFFu), unpack565(b.x >> 16) };
        int3 q[2];
        uint pb[2];
        // Each endpoint takes the p-bit (shared by its channels) that lands nearest
        for (int j = 0; j < 2; j++) {
            int3 even = clamp((e[j] + 1) >> 1, 0, 127), odd = clamp((e[j] - 1) >> 1, 0, 127);
            int3 d0 = abs(even * 2 - e[j]), d1 = abs(odd * 2 + 1 - e[j]);
            bool useOdd = d1.x + d1.y + d1.z < d0.x + d0.y + d0.z;
            q[j] = useOdd ? odd : even;
            pb[j] = useOdd ? 1u : 0u;
        }
        uchar idx[16];
        for (uint k = 0; k < 16; k++) idx[k] = kBC1Index[(b.y >> (2 * k)) & 3u];
        dst[i] = packMode6(q[0], q[1], pb[0], pb[1], idx);
    }
    """

    public init(device: MTLDevice) {
        transcoder = (try? device.makeLibrary(source: TileTexture.shaders, options: nil))
            .flatMap { $0.makeFunction(name: "bc1ToBC7") }
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.device = device
        for _ in 0..<TileTexture.stagingCount { free.signal() }
        scratch = (0..<TileFrame.maxChunks).map { _ in
            LZ4.decodeScratchSize > 0 ? UnsafeMutableRawPointer.allocate(byteCount: LZ4.decodeScratchSize, alignment: 16) : nil
        }
        BufferPool.shared.addUnmapObserver { [weak self] p in
            guard let self = self else { return }
            self.wrapLock.lock()
            self.wraps[p] = nil
            self.wrapLock.unlock()
        }
    }

    deinit { scratch.forEach { $0?.deallocate() } }

    public func ensure(geometry g: TileGeometry) {
        guard geometry != g else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm, width: g.width, height: g.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        texture = device.makeTexture(descriptor: desc)
        geometry = g
        staging = []
    }

    /// Throws when a chunk fails to decode; the texture is left unchanged
    public func encodeUpload(_ frame: TileFrame, into cb: MTLCommandBuffer) throws {
        guard let texture = texture, let g = geometry, frame.rawBytes > 0 else { return }
        if frame.chunks.allSatisfy({ !$0.compressed }), let source = wrap(frame.payload) {
            try encodeRuns(frame, from: source, offset: frame.dataOffset, to: texture, geometry: g, into: cb)
            lastDecodeMs = 0
            // The pooled buffer must not be reused before the GPU has read it
            cb.addCompletedHandler { _ in _ = frame }
            return
        }
        free.wait()
        let frameBytes = g.blocksX * g.blocksY * BC7.blockBytes
        if staging.isEmpty {
            staging = (0..<TileTexture.stagingCount).compactMap { _ in device.makeBuffer(length: frameBytes, options: .storageModeShared) }
        }
        guard staging.count == TileTexture.stagingCount, frame.rawBytes <= frameBytes else {
            free.signal()
            throw FramingError.invalid("tile upload")
        }
        let buffer = staging[ring]

        let start = ProcessInfo.processInfo.systemUptime
        let base = buffer.contents()
        var failed = 0
        withUnsafeMutablePointer(to: &failed) { flag in
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: frame.chunks.count) { i in
                do {
                    try frame.decode(chunk: i, into: base, scratch: scratch[i])
                } catch {
                    lock.lock()
                    flag.pointee = 1
                    lock.unlock()
                }
            }
        }
        lastDecodeMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard failed == 0 else {
            free.signal()
            throw FramingError.invalid("tile data")
        }

        do {
            try encodeRuns(frame, from: buffer, offset: 0, to: texture, geometry: g, into: cb)
        } catch {
            free.signal()
            throw error
        }
        // Only a frame that will read this buffer moves the ring on
        ring = (ring + 1) % staging.count
        let semaphore = free
        cb.addCompletedHandler { _ in semaphore.signal() }
    }

    /// BC1 blocks (contiguous at the end of the raw stream) are transcoded in one dispatch,
    /// then every run is blitted: BC7 runs from `source`, BC1 runs from the transcoded buffer
    private func encodeRuns(_ frame: TileFrame, from source: MTLBuffer, offset start: Int, to texture: MTLTexture,
                            geometry g: TileGeometry, into cb: MTLCommandBuffer) throws {
        let bc1 = frame.bc1Span
        if bc1.blocks > 0 {
            let frameBytes = g.blocksX * g.blocksY * BC7.blockBytes
            if (transcoded?.length ?? 0) < frameBytes {
                transcoded = device.makeBuffer(length: frameBytes, options: .storageModePrivate)
            }
            guard let pipeline = transcoder, let out = transcoded, bc1.blocks * BC7.blockBytes <= out.length,
                  let enc = cb.makeComputeCommandEncoder() else { throw FramingError.invalid("tile transcode") }
            var count = UInt32(bc1.blocks)
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(source, offset: start + bc1.offset, index: 0)
            enc.setBuffer(out, offset: 0, index: 1)
            enc.setBytes(&count, length: 4, index: 2)
            // Uniform threadgroups: the kernel bounds-checks, and every Mac GPU supports them
            enc.dispatchThreadgroups(MTLSize(width: (bc1.blocks + 63) / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }
        guard let blit = cb.makeBlitCommandEncoder() else { throw FramingError.invalid("tile upload") }
        var offset = start, transcodedOffset = 0
        for run in frame.runs where run.format != .video {
            let b = run.blocks(in: g), size = run.size(in: g), origin = run.origin(in: g)
            let from = run.format == .bc7 ? source : transcoded!
            let at = run.format == .bc7 ? offset : transcodedOffset
            blit.copy(from: from, sourceOffset: at, sourceBytesPerRow: b.w * BC7.blockBytes,
                      sourceBytesPerImage: b.w * b.h * BC7.blockBytes, sourceSize: MTLSize(width: size.w, height: size.h, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: origin.x, y: origin.y, z: 0))
            if run.format == .bc7 { offset += b.w * b.h * BC7.blockBytes } else { transcodedOffset += b.w * b.h * BC7.blockBytes }
        }
        blit.endEncoding()
    }

    /// The payload's own memory as a Metal buffer, when it is a pooled (mmap'd) buffer.
    /// Payload offsets match buffer offsets because pooled payloads start at the mapping
    private func wrap(_ payload: Data) -> MTLBuffer? {
        payload.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress, let capacity = BufferPool.shared.capacity(of: base) else { return nil }
            let key = UnsafeMutableRawPointer(mutating: base)
            wrapLock.lock()
            defer { wrapLock.unlock() }
            if let cached = wraps[key] { return cached }
            guard let buffer = device.makeBuffer(bytesNoCopy: key, length: capacity,
                                                 options: [.storageModeShared, .hazardTrackingModeUntracked], deallocator: nil) else { return nil }
            wraps[key] = buffer
            wrappedBuffers += 1
            return buffer
        }
    }

    /// Frees the texture and staging buffers; the next frame allocates them again
    public func release() {
        texture = nil
        geometry = nil
        transcoded = nil
        staging = []
        ring = 0
    }
}
