import CoreGraphics
import Foundation
import Metal
import AfterscreenCore

public enum TileEncoderError: Error {
    case metal(String)
}

/// Dirty runs and their blocks, row-major within each run.
/// `data` aliases an upload buffer, returned with its last copy
public struct EncodedFrame {
    public let runs: [TileRun]
    public let data: Data

    public var tileCount: Int { runs.reduce(0) { $0 + $1.count } }
}

/// BGRA → BC7 mode 6 tiles on the GPU.
/// Encodes tiles under the dirty rects plus a rolling refresh slice,
/// diffs them against the reference, gathers changed runs for upload.
/// Tiles that keep changing go out as BC1 at half the size; once they settle,
/// their BC7 reference follows. The reference always holds BC7
public final class TileEncoder {
    public let geometry: TileGeometry
    public private(set) var lastGPUSeconds: Double = 0

    private let queue: MTLCommandQueue
    private let encodePipeline: MTLComputePipelineState
    private let diffPipeline: MTLComputePipelineState
    private let gatherPipeline: MTLComputePipelineState
    private let cur: MTLBuffer
    private let ref: MTLBuffer
    private let dirtyFlags: MTLBuffer
    private let tileTable: MTLBuffer
    private let candidateList: MTLBuffer
    private var candidates: [Bool]
    /// Seconds within which a tile must change again to count as moving
    public static let motionWindow: TimeInterval = 0.05
    /// On a link-bound stream: a tile changed in consecutive frames this close together is moving (≥ 2 fps)
    public static let congestedMotionWindow: TimeInterval = 0.5
    /// Seconds a BC1 tile stays unchanged before its BC7 reference is sent
    public static let settleDelay: TimeInterval = 0.1
    private var lastChange: [TimeInterval]
    /// Encode count at each tile's last change; a link-bound stream compares frames, not time
    private var lastFrame: [Int]
    private var encodes = 0
    /// The receiver holds the BC1 version of these tiles
    private var lossy: [Bool]
    /// Gather mode per tile: 0 BC7 from cur, 1 BC7 from ref, 2 BC1 from the texture
    private var modes: [UInt32]
    /// Bound during refinement passes, which read no pixels
    private let placeholder: MTLTexture
    /// Next tile of the rolling refresh; one full sweep every `refreshFrames` frames
    private var refreshCursor = 0
    static let refreshFrames = 64
    private var params: [UInt32]
    private let uploads: [MTLBuffer]
    private let uploadLock = NSLock()
    private var freeUploads: [Int]
    /// Free upload buffers; starts at 0 and counts up (release below the initial value traps)
    private let uploadSlots = DispatchSemaphore(value: 0)

    /// `uploadBuffers` bounds the encoded frames that can wait in the send queue
    public init(device: MTLDevice, geometry: TileGeometry, uploadBuffers: Int = 3) throws {
        self.geometry = geometry
        guard let queue = device.makeCommandQueue() else { throw TileEncoderError.metal("command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: Shaders.tileEncoder, options: nil)
        guard let encodeFn = library.makeFunction(name: "bc7Encode"),
              let diffFn = library.makeFunction(name: "tileDiff"),
              let gatherFn = library.makeFunction(name: "tileGather") else {
            throw TileEncoderError.metal("shader functions")
        }
        encodePipeline = try device.makeComputePipelineState(function: encodeFn)
        diffPipeline = try device.makeComputePipelineState(function: diffFn)
        gatherPipeline = try device.makeComputePipelineState(function: gatherFn)
        let tileMajor = geometry.tileCount * geometry.tileBytes
        let frameBytes = geometry.blocksX * geometry.blocksY * BC7.blockBytes
        guard let cur = device.makeBuffer(length: tileMajor, options: .storageModeShared),
              let ref = device.makeBuffer(length: tileMajor, options: .storageModeShared),
              let dirty = device.makeBuffer(length: geometry.tileCount * 4, options: .storageModeShared),
              let table = device.makeBuffer(length: geometry.tileCount * 16, options: .storageModeShared),
              let list = device.makeBuffer(length: geometry.tileCount * 4, options: .storageModeShared),
              let placeholder = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
                  pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)) else {
            throw TileEncoderError.metal("buffers")
        }
        self.cur = cur
        self.ref = ref
        dirtyFlags = dirty
        tileTable = table
        candidateList = list
        candidates = [Bool](repeating: false, count: geometry.tileCount)
        lastChange = [TimeInterval](repeating: -.infinity, count: geometry.tileCount)
        lastFrame = [Int](repeating: -2, count: geometry.tileCount)
        lossy = [Bool](repeating: false, count: geometry.tileCount)
        modes = [UInt32](repeating: 0, count: geometry.tileCount)
        self.placeholder = placeholder
        uploads = try (0..<max(1, uploadBuffers)).map { _ in
            guard let b = device.makeBuffer(length: frameBytes, options: .storageModeShared) else { throw TileEncoderError.metal("upload buffer") }
            return b
        }
        freeUploads = Array(uploads.indices)
        for _ in uploads { uploadSlots.signal() }
        params = [geometry.width, geometry.height, geometry.blocksX, geometry.blocksY,
                  geometry.tilesX, geometry.tileBlocks, geometry.tileCount, 0].map(UInt32.init)
    }

    /// Last encoded picture, tile-major
    public var reference: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: ref.contents(), count: ref.length) }

    /// Byte offset of block (bx, by) in tile-major order
    public static func blockOffset(bx: Int, by: Int, geometry g: TileGeometry) -> Int {
        let tile = (by / g.tileBlocks) * g.tilesX + bx / g.tileBlocks
        let local = (by % g.tileBlocks) * g.tileBlocks + bx % g.tileBlocks
        return (tile * g.tileBlocks * g.tileBlocks + local) * BC7.blockBytes
    }

    /// Marks tiles that `rects` (stream pixels) touch
    static func markTiles(under rects: [CGRect], geometry g: TileGeometry, into marks: inout [Bool]) {
        let bounds = CGRect(x: 0, y: 0, width: g.width, height: g.height)
        let size = CGFloat(g.tilePixels)
        for rect in rects {
            let r = rect.intersection(bounds)
            guard !r.isNull, !r.isEmpty else { continue }
            let x0 = Int(r.minX / size), x1 = Int((r.maxX / size).rounded(.up)) - 1
            let y0 = Int(r.minY / size), y1 = Int((r.maxY / size).rounded(.up)) - 1
            for y in y0...y1 {
                for x in x0...x1 { marks[y * g.tilesX + x] = true }
            }
        }
    }

    /// Synchronous. `dirty` is the capture's changed regions in stream pixels; nil encodes every tile.
    /// `congested`: the link held frames back, so a tile that also changed in the previous frame is moving
    /// however far apart the frames are. Settled BC1 tiles ride along as BC7.
    /// nil when nothing is to be sent, or when every upload buffer stayed in use for a second
    public func encode(texture: MTLTexture, forceAll: Bool, dirty: [CGRect]?,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime, congested: Bool = false) -> EncodedFrame? {
        let list = candidateList.contents().assumingMemoryBound(to: UInt32.self)
        var count = 0
        if forceAll || dirty == nil {
            for t in 0..<geometry.tileCount { list[t] = UInt32(t) }
            count = geometry.tileCount
        } else {
            candidates.withUnsafeMutableBufferPointer { $0.update(repeating: false) }
            TileEncoder.markTiles(under: dirty ?? [], geometry: geometry, into: &candidates)
            let slice = max(1, (geometry.tileCount + TileEncoder.refreshFrames - 1) / TileEncoder.refreshFrames)
            for i in 0..<slice { candidates[(refreshCursor + i) % geometry.tileCount] = true }
            refreshCursor = (refreshCursor + slice) % geometry.tileCount
            for t in 0..<geometry.tileCount where candidates[t] {
                list[count] = UInt32(t)
                count += 1
            }
        }
        params[7] = UInt32(count)
        let flags = UnsafeMutableBufferPointer(start: dirtyFlags.contents().assumingMemoryBound(to: UInt32.self), count: geometry.tileCount)
        flags.update(repeating: 0)

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(encodePipeline)
        enc.setTexture(texture, index: 0)
        enc.setBuffer(cur, offset: 0, index: 0)
        enc.setBytes(&params, length: params.count * 4, index: 1)
        enc.setBuffer(candidateList, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: geometry.tileBlocks, height: geometry.tileBlocks, depth: count),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.setComputePipelineState(diffPipeline)
        enc.setBuffer(cur, offset: 0, index: 0)
        enc.setBuffer(ref, offset: 0, index: 1)
        enc.setBuffer(dirtyFlags, offset: 0, index: 2)
        enc.setBytes(&params, length: params.count * 4, index: 3)
        enc.setBuffer(candidateList, offset: 0, index: 4)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(64, count), height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        lastGPUSeconds = max(0, cb.gpuEndTime - cb.gpuStartTime)

        if forceAll { flags.update(repeating: 1) }
        encodes += 1
        var settling: [Int] = []
        for t in 0..<geometry.tileCount {
            if flags[t] != 0 {
                let since = now - lastChange[t]
                let moving = !forceAll && (since < TileEncoder.motionWindow
                    || (congested && lastFrame[t] == encodes - 1 && since < TileEncoder.congestedMotionWindow))
                lastChange[t] = now
                lastFrame[t] = encodes
                lossy[t] = moving
                mark(t, mode: moving ? 2 : 0, in: flags)
            } else if lossy[t] && now - lastChange[t] >= TileEncoder.settleDelay {
                settling.append(t)
                mark(t, mode: 1, in: flags)
            }
        }
        return settle(settling, gather(texture: texture))
    }

    /// Settling tiles leave the lossy set only once their BC7 version is on its way
    private func settle(_ tiles: [Int], _ frame: EncodedFrame?) -> EncodedFrame? {
        if frame != nil { tiles.forEach { lossy[$0] = false } }
        return frame
    }

    /// Sends the BC7 reference of BC1 tiles that have settled; nil when none have
    public func refine(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EncodedFrame? {
        let flags = UnsafeMutableBufferPointer(start: dirtyFlags.contents().assumingMemoryBound(to: UInt32.self), count: geometry.tileCount)
        flags.update(repeating: 0)
        let settling = (0..<geometry.tileCount).filter { lossy[$0] && now - lastChange[$0] >= TileEncoder.settleDelay }
        settling.forEach { mark($0, mode: 1, in: flags) }
        lastGPUSeconds = 0
        return settling.isEmpty ? nil : settle(settling, gather(texture: placeholder))
    }

    /// Seconds until the next BC1 tile settles; nil when none is pending
    public func nextRefinement(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        var soonest: TimeInterval?
        for t in 0..<geometry.tileCount where lossy[t] {
            let due = max(0, lastChange[t] + TileEncoder.settleDelay - now)
            soonest = min(soonest ?? due, due)
        }
        return soonest
    }

    private func mark(_ tile: Int, mode: UInt32, in flags: UnsafeMutableBufferPointer<UInt32>) {
        modes[tile] = mode
        flags[tile] = UInt32((mode == 2 ? TileFormat.bc1 : .bc7).rawValue) + 1
    }

    /// Writes the marked tiles' runs into a free upload buffer
    private func gather(texture: MTLTexture) -> EncodedFrame? {
        let flags = UnsafeBufferPointer(start: dirtyFlags.contents().assumingMemoryBound(to: UInt32.self), count: geometry.tileCount)
        let runs = TileRun.runs(marks: flags, geometry: geometry)
        guard !runs.isEmpty, let slot = acquireUpload() else { return nil }
        let upload = uploads[slot]

        // Per sent tile: index, first output unit (8 bytes), run width in blocks, gather mode
        let table = tileTable.contents().assumingMemoryBound(to: UInt32.self)
        var tiles = 0, outUnits = 0
        for run in runs {
            let b = run.blocks(in: geometry)
            let units = run.format.blockBytes / 8
            for t in 0..<run.count {
                let tile = run.row * geometry.tilesX + run.first + t
                table[tiles * 4] = UInt32(tile)
                table[tiles * 4 + 1] = UInt32(outUnits + t * geometry.tileBlocks * units)
                table[tiles * 4 + 2] = UInt32(b.w)
                table[tiles * 4 + 3] = modes[tile]
                tiles += 1
            }
            outUnits += b.w * b.h * units
        }
        guard let gcb = queue.makeCommandBuffer(), let genc = gcb.makeComputeCommandEncoder() else {
            releaseUpload(slot)
            return nil
        }
        genc.setComputePipelineState(gatherPipeline)
        genc.setTexture(texture, index: 0)
        genc.setBuffer(cur, offset: 0, index: 0)
        genc.setBuffer(ref, offset: 0, index: 1)
        genc.setBuffer(upload, offset: 0, index: 2)
        genc.setBuffer(tileTable, offset: 0, index: 3)
        genc.setBytes(&params, length: params.count * 4, index: 4)
        genc.dispatchThreads(MTLSize(width: geometry.tileBlocks, height: geometry.tileBlocks, depth: tiles),
                             threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        genc.endEncoding()
        gcb.commit()
        gcb.waitUntilCompleted()
        lastGPUSeconds += max(0, gcb.gpuEndTime - gcb.gpuStartTime)

        // The buffer stays alive and reserved until the last copy of `data` is released
        let data = Data(bytesNoCopy: upload.contents(), count: outUnits * 8, deallocator: .custom { [upload, weak self] _, _ in
            _ = upload
            self?.releaseUpload(slot)
        })
        return EncodedFrame(runs: runs, data: data)
    }

    private func acquireUpload() -> Int? {
        guard uploadSlots.wait(timeout: .now() + 1) == .success else { return nil }
        uploadLock.lock()
        defer { uploadLock.unlock() }
        return freeUploads.popLast()
    }

    private func releaseUpload(_ slot: Int) {
        uploadLock.lock()
        freeUploads.append(slot)
        uploadLock.unlock()
        uploadSlots.signal()
    }
}
