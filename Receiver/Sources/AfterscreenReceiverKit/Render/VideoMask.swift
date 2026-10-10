import AfterscreenCore

/// Tiles showing the video layer
/// Video runs set them; BC7 and BC1 runs clear them
struct VideoMask {
    private(set) var bytes: [UInt8] = []
    /// Number of set tiles
    private(set) var shown = 0
    private var geometry: TileGeometry?

    mutating func apply(_ runs: [TileRun], geometry g: TileGeometry) {
        if geometry != g {
            bytes = [UInt8](repeating: 0, count: g.tileCount)
            shown = 0
            geometry = g
        }
        for run in runs {
            let value: UInt8 = run.format == .video ? 1 : 0
            let base = run.row * g.tilesX + run.first
            for t in base..<(base + run.count) where bytes[t] != value {
                bytes[t] = value
                shown += value == 1 ? 1 : -1
            }
        }
    }

    mutating func reset() {
        bytes = []
        shown = 0
        geometry = nil
    }
}
