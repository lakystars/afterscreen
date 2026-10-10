import Foundation
import Metal
import AfterscreenCore

/// Debanded copy of the BC7 picture in 10-bit. Only tiles a frame changed, and tiles within the
/// smoothing reach of them, are recomputed; a still screen costs one sample per pixel to draw.
/// Decode queue only
final class DebandCache {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private(set) var texture: MTLTexture?
    private var geometry: TileGeometry?
    private var range: Float = 0
    /// Tiles whose source changed since the last update
    private var marks: [Bool] = []

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

    /// The debanded picture, with marked tiles and their reach recomputed into `cb`;
    /// everything after a size or level change. nil when `range` is 0 (off)
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
        marks = [Bool](repeating: false, count: g.tileCount)
        guard !tiles.isEmpty, let enc = cb.makeComputeCommandEncoder() else { return target }
        var grid = [UInt32(g.width), UInt32(g.height), UInt32(g.tilesX), UInt32(g.tilePixels), range.bitPattern]
        enc.setComputePipelineState(pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(target, index: 1)
        enc.setBytes(&grid, length: grid.count * 4, index: 0)
        enc.setBytes(tiles, length: tiles.count * 4, index: 1)
        enc.dispatchThreads(MTLSize(width: g.tilePixels, height: g.tilePixels, depth: tiles.count),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        return target
    }

    /// Drops the picture; the next update recomputes everything
    func release() {
        texture = nil
        geometry = nil
        marks = []
    }

    /// Tiles within `margin` tiles of a marked one, in tile order
    static func reach(_ marks: [Bool], tilesX: Int, tilesY: Int, margin: Int) -> [UInt32] {
        var grown = [Bool](repeating: false, count: marks.count)
        for t in marks.indices where marks[t] {
            let x = t % tilesX, y = t / tilesX
            for gy in max(0, y - margin)...min(tilesY - 1, y + margin) {
                for gx in max(0, x - margin)...min(tilesX - 1, x + margin) { grown[gy * tilesX + gx] = true }
            }
        }
        return grown.indices.filter { grown[$0] }.map(UInt32.init)
    }
}
