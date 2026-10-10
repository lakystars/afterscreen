/// Per-frame LZ4 decision
/// Frames within link headroom go stored
/// A copy costs less than LZ4 on both ends
/// Bigger frames, or any under congestion, compress while compressible
/// Incompressible content rechecked with one chunk every `probeInterval` frames
public struct CompressionPolicy {
    public static let minRatio = 1.25
    public static let probeInterval = 30
    /// Frames treated as congested after a full send queue
    public static let congestionFrames = 120
    /// Link capacity wanted over the frame's rate at 60 fps
    static let headroom = 1.3

    private let capacityBits: Double
    private var congested = 0
    private var compressible = true
    private var untilProbe = 0

    public init(capacityGbps: Double?) {
        capacityBits = (capacityGbps ?? 0) * 1e9
    }

    /// `queueWasFull`: link held a frame back since the previous call
    public mutating func next(rawBytes: Int, queueWasFull: Bool) -> TilePacker.Compression {
        if queueWasFull { congested = CompressionPolicy.congestionFrames }
        let tooBig = Double(rawBytes) * 8 * 60 * CompressionPolicy.headroom > capacityBits
        guard tooBig || congested > 0 else { return .none }
        congested = max(0, congested - 1)
        if compressible { return .all }
        untilProbe -= 1
        return untilProbe <= 0 ? .firstChunk : .none
    }

    /// LZ4 input and output bytes of the last frame
    public mutating func record(rawBytes: Int, wireBytes: Int) {
        guard rawBytes > 0 else { return }
        compressible = Double(rawBytes) >= Double(max(1, wireBytes)) * CompressionPolicy.minRatio
        if !compressible { untilProbe = CompressionPolicy.probeInterval }
    }
}
