import CoreGraphics
import Foundation
import Metal
import AfterscreenCore

public enum TileEncoderError: Error {
    case metal(String)
}

/// Dirty runs and their blocks, row-major within each run
/// `data` aliases an upload buffer, returned with its last copy
public struct EncodedFrame {
    public let runs: [TileRun]
    public let data: Data

    public var tileCount: Int { runs.reduce(0) { $0 + $1.count } }
}

/// BGRA → BC7 mode 6 tiles on the GPU
/// Encodes tiles under dirty rects plus a rolling refresh slice
/// Diffs against the reference; gathers changed runs for upload
/// Moving tiles: half-size BC1, or the video layer
/// Once settled, their BC7 reference follows
/// The reference always holds BC7
public final class TileEncoder {
    /// What the receiver shows for tiles in motion
    public enum Motion {
        /// BC1 data on every change
        case bc1
        /// Video run on motion start; nothing until the tile settles
        case video
    }

    public let geometry: TileGeometry
    public private(set) var lastGPUSeconds: Double = 0
    public var motion = Motion.bc1
    /// Max settled tiles sent per frame
    /// Keeps a big refinement from stalling motion on slow links
    public var settleLimit = Int.max
    /// BC1 motion path: max moving tiles per frame as BC7
    /// Exceeded: all moving tiles go out as BC1
    public var bc7MotionLimit = 0
    /// Tiles the receiver shows lossy: BC1, or the video layer
    public private(set) var lossyTiles = 0
    /// Tiles that differ from the reference in the last frame
    /// Video-carried tiles too, unlike the frame's runs
    public private(set) var changedTiles = 0

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
    /// Tile changing again within this many seconds counts as moving
    public static let motionWindow: TimeInterval = 0.05
    /// Link-bound stream: motion window for consecutive-frame changes (≥ 2 fps)
    /// Sustained congestion, frames further apart: 1.5 frame intervals
    public static let congestedMotionWindow: TimeInterval = 0.5
    /// Unchanged seconds before a lossy tile's BC7 reference is sent
    public static let settleDelay: TimeInterval = 0.1
    private var lastChange: [TimeInterval]
    /// Encode count at each tile's last change
    /// Link-bound stream compares frames, not time
    private var lastFrame: [Int]
    private var encodes = 0
    private var lastEncode = -TimeInterval.infinity
    private var lastCongested = false
    /// Receiver shows these tiles as BC1 or video
    private var lossy: [Bool]
    /// Shown from the video layer; BC1 tiles are lossy only
    /// Kept apart: the motion mode may change mid-session
    private var onVideo: [Bool]
    /// Gather mode per tile
    /// 0 BC7 from cur, 1 BC7 from ref
    /// 2 BC1 from the texture, 3 reference only
    private var modes: [UInt32]
    /// Bound during refinement passes, which read no pixels
    private let placeholder: MTLTexture
    /// Next rolling-refresh tile; full sweep every `refreshFrames` frames
    private var refreshCursor = 0
    static let refreshFrames = 64
    private var params: [UInt32]
    private let uploads: [MTLBuffer]
    private let uploadLock = NSLock()
    private var freeUploads: [Int]
    /// Free upload buffers; starts at 0 and counts up
    /// Releasing below the initial value traps
    private let uploadSlots = DispatchSemaphore(value: 0)

    /// `uploadBuffers` bounds encoded frames waiting in the send queue
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
        onVideo = [Bool](repeating: false, count: geometry.tileCount)
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

    /// Synchronous
    /// `dirty`: capture's changed regions in stream pixels; nil encodes all
    /// `congested`: stream lags its source
    /// Then a tile also changed last frame is moving
    /// Settled BC1 tiles are sent along as BC7
    /// nil when there is nothing to send
    /// or no upload buffer frees up within 1 s
    public func encode(texture: MTLTexture, forceAll: Bool, dirty: [CGRect]?,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime, congested: Bool = false) -> EncodedFrame? {
        changedTiles = 0
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
        // Gap after an uncongested frame means pause, not slow link
        // Full frames count as congested: slowest to send
        let congestedWindow = lastCongested ? max(TileEncoder.congestedMotionWindow, 1.5 * (now - lastEncode)) : TileEncoder.congestedMotionWindow
        lastEncode = now
        lastCongested = congested || forceAll
        var settling: [Int] = [], entering: [Int] = [], referenceOnly: [Int] = [], moving: [Int] = []
        var changed = 0
        for t in 0..<geometry.tileCount {
            if flags[t] != 0 {
                changed += 1
                let since = now - lastChange[t]
                // Lossy tile counts as moving until still for `settleDelay`
                let inMotion = !forceAll && (since < TileEncoder.motionWindow || (lossy[t] && since < TileEncoder.settleDelay)
                    || (congested && lastFrame[t] == encodes - 1 && since < congestedWindow))
                lastChange[t] = now
                lastFrame[t] = encodes
                if inMotion && motion == .video {
                    // Video tiles become lossy once a frame carries their run
                    if onVideo[t] {
                        flags[t] = 0
                        modes[t] = 3
                        referenceOnly.append(t)
                    } else {
                        mark(t, mode: 3, in: flags)
                        entering.append(t)
                    }
                    continue
                }
                if inMotion {
                    moving.append(t)
                } else {
                    lossy[t] = false
                    onVideo[t] = false
                    mark(t, mode: 0, in: flags)
                }
            } else if lossy[t] && now - lastChange[t] >= TileEncoder.settleDelay && settling.count < settleLimit {
                settling.append(t)
                mark(t, mode: 1, in: flags)
            }
        }
        // Motion within the link's BC7 budget stays BC7
        // Past it, all moving tiles drop to half-size BC1
        let sharp = moving.count <= bc7MotionLimit
        for t in moving {
            lossy[t] = !sharp
            onVideo[t] = false
            mark(t, mode: sharp ? 0 : 2, in: flags)
        }
        let frame = gather(texture: texture, referenceOnly: referenceOnly)
        if frame != nil {
            for t in entering {
                lossy[t] = true
                onVideo[t] = true
            }
        }
        changedTiles = changed
        return settle(settling, frame)
    }

    /// Settling tiles stay lossy until a frame carries their BC7
    private func settle(_ tiles: [Int], _ frame: EncodedFrame?) -> EncodedFrame? {
        if frame != nil {
            for t in tiles {
                lossy[t] = false
                onVideo[t] = false
            }
        }
        lossyTiles = lossy.reduce(0) { $1 ? $0 + 1 : $0 }
        return frame
    }

    /// The receiver may have missed frames: every tile goes again
    /// As BC7 references, over the next refinements
    public func resyncAll() {
        for t in 0..<geometry.tileCount {
            lossy[t] = true
            onVideo[t] = false
        }
        lossyTiles = geometry.tileCount
    }

    /// BC7 reference of settled lossy tiles; nil when none
    public func refine(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EncodedFrame? {
        let flags = UnsafeMutableBufferPointer(start: dirtyFlags.contents().assumingMemoryBound(to: UInt32.self), count: geometry.tileCount)
        flags.update(repeating: 0)
        let settling = Array((0..<geometry.tileCount).lazy
            .filter { self.lossy[$0] && now - self.lastChange[$0] >= TileEncoder.settleDelay }
            .prefix(settleLimit))
        settling.forEach { mark($0, mode: 1, in: flags) }
        lastGPUSeconds = 0
        return settling.isEmpty ? nil : settle(settling, gather(texture: placeholder, referenceOnly: []))
    }

    /// Seconds until the next lossy tile settles; nil if none
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
        let format: TileFormat = mode == 2 ? .bc1 : (mode == 3 ? .video : .bc7)
        flags[tile] = UInt32(format.rawValue) + 1
    }

    /// Writes marked tiles' runs into a free upload buffer
    /// `referenceOnly` tiles only update the reference
    /// nil: no run to send, or no upload buffer free
    private func gather(texture: MTLTexture, referenceOnly: [Int]) -> EncodedFrame? {
        let flags = UnsafeBufferPointer(start: dirtyFlags.contents().assumingMemoryBound(to: UInt32.self), count: geometry.tileCount)
        let runs = TileRun.runs(marks: flags, geometry: geometry)
        guard !runs.isEmpty || !referenceOnly.isEmpty else { return nil }

        // Per tile: index, first output unit (8 bytes),
        // run width in blocks, gather mode
        let table = tileTable.contents().assumingMemoryBound(to: UInt32.self)
        var tiles = 0, outUnits = 0
        func entry(_ tile: Int, _ base: Int, _ width: Int) {
            table[tiles * 4] = UInt32(tile)
            table[tiles * 4 + 1] = UInt32(base)
            table[tiles * 4 + 2] = UInt32(width)
            table[tiles * 4 + 3] = modes[tile]
            tiles += 1
        }
        for run in runs {
            let b = run.blocks(in: geometry)
            let units = run.format.blockBytes / 8
            for t in 0..<run.count { entry(run.row * geometry.tilesX + run.first + t, outUnits + t * geometry.tileBlocks * units, b.w) }
            outUnits += b.w * b.h * units
        }
        referenceOnly.forEach { entry($0, 0, 0) }
        var slot: Int?
        if outUnits > 0 {
            guard let free = acquireUpload() else { return nil }
            slot = free
        }
        guard let gcb = queue.makeCommandBuffer(), let genc = gcb.makeComputeCommandEncoder() else {
            slot.map(releaseUpload)
            return nil
        }
        genc.setComputePipelineState(gatherPipeline)
        genc.setTexture(texture, index: 0)
        genc.setBuffer(cur, offset: 0, index: 0)
        genc.setBuffer(ref, offset: 0, index: 1)
        // Reference-only passes write no output
        genc.setBuffer(slot.map { uploads[$0] } ?? cur, offset: 0, index: 2)
        genc.setBuffer(tileTable, offset: 0, index: 3)
        genc.setBytes(&params, length: params.count * 4, index: 4)
        genc.dispatchThreads(MTLSize(width: geometry.tileBlocks, height: geometry.tileBlocks, depth: tiles),
                             threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        genc.endEncoding()
        gcb.commit()
        gcb.waitUntilCompleted()
        lastGPUSeconds += max(0, gcb.gpuEndTime - gcb.gpuStartTime)

        guard !runs.isEmpty else { return nil }
        guard let slot = slot else { return EncodedFrame(runs: runs, data: Data()) }
        // Buffer stays alive and reserved until last `data` copy releases
        let upload = uploads[slot]
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
