import Foundation
import Metal
import AfterscreenCore

/// Debanded 10-bit copy of the BC7 picture
/// Recomputes only changed tiles and tiles within smoothing reach
/// A still screen costs one sample per pixel to draw
/// Decode queue only
final class DebandCache {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private(set) var texture: MTLTexture?
    private var geometry: TileGeometry?
    private var range: Float = 0
    /// Tiles whose source changed since the last update
    private var marks: [Bool] = []
    private let listLock = NSLock()
    /// Tile list buffers returned by completed passes
    /// Lists past 4 KB cannot go through setBytes
    private var freeLists: [MTLBuffer] = []

    /// `library`: compiled `StreamRenderer.shaders`, shared with the renderer
    init?(device: MTLDevice, library: MTLLibrary? = nil) {
        guard let lib = library ?? (try? device.makeLibrary(source: StreamRenderer.shaders, options: nil)),
              let fn = lib.makeFunction(name: "debandTiles"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        self.pipeline = pipeline
    }

    /// Marks the tiles `runs` touched
    func mark(_ runs: [TileRun], geometry g: TileGeometry) {
        guard g == geometry, marks.count == g.tileCount else { return }
        for run in runs {
            let base = run.row * g.tilesX + run.first
            for t in base..<min(base + run.count, marks.count) { marks[t] = true }
        }
    }

    /// Debanded picture; encodes marked tiles and their reach into `cb`
    /// All tiles after a size or level change
    /// nil when `range` is 0 (off)
    func update(source: MTLTexture, geometry g: TileGeometry, range: Float, into cb: MTLCommandBuffer) -> MTLTexture? {
        guard range > 0 else { return nil }
        if g != geometry || range != self.range || texture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgb10a2Unorm, width: g.width, height: g.height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            if g != geometry || texture == nil { texture = device.makeTexture(descriptor: desc) }
            geometry = g
            self.range = range
            marks = [Bool](repeating: true, count: g.tileCount)
        }
        guard let target = texture else { return nil }
        let margin = Int((3 * range / Float(g.tilePixels)).rounded(.up))
        let tiles = DebandCache.reach(marks, tilesX: g.tilesX, tilesY: g.tilesY, margin: margin)
        // Marks stay set until a pass is encoded
        guard !tiles.isEmpty, let list = takeList(bytes: g.tileCount * 4) else { return target }
        guard let enc = cb.makeComputeCommandEncoder() else {
            recycle(list)
            return target
        }
        marks.withUnsafeMutableBufferPointer { $0.update(repeating: false) }
        tiles.withUnsafeBytes { list.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        var grid = [UInt32(g.width), UInt32(g.height), UInt32(g.tilesX), UInt32(g.tilePixels), range.bitPattern]
        enc.setComputePipelineState(pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(target, index: 1)
        enc.setBytes(&grid, length: grid.count * 4, index: 0)
        enc.setBuffer(list, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: g.tilePixels, height: g.tilePixels, depth: tiles.count),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.addCompletedHandler { [weak self] _ in self?.recycle(list) }
        return target
    }

    /// Drops the picture; the next update recomputes everything
    func release() {
        texture = nil
        geometry = nil
        marks = []
        listLock.lock()
        freeLists = []
        listLock.unlock()
    }

    /// Free list buffer of ≥ `bytes`, else a new one
    private func takeList(bytes: Int) -> MTLBuffer? {
        listLock.lock()
        let free = freeLists.popLast()
        listLock.unlock()
        if let free = free, free.length >= bytes { return free }
        return device.makeBuffer(length: bytes, options: .storageModeShared)
    }

    private func recycle(_ list: MTLBuffer) {
        listLock.lock()
        freeLists.append(list)
        listLock.unlock()
    }

    /// Tiles within `margin` of a marked tile, in tile order
    static func reach(_ marks: [Bool], tilesX: Int, tilesY: Int, margin: Int) -> [UInt32] {
        var grown = [Bool](repeating: false, count: marks.count)
        for t in marks.indices where marks[t] {
            let x = t % tilesX, y = t / tilesX
            for gy in max(0, y - margin)...min(tilesY - 1, y + margin) {
                for gx in max(0, x - margin)...min(tilesX - 1, x + margin) { grown[gy * tilesX + gx] = true }
            }
        }
        var tiles: [UInt32] = []
        for t in grown.indices where grown[t] { tiles.append(UInt32(t)) }
        return tiles
    }
}
