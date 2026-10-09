/// Per-frame LZ4 decision.
/// Frames the link carries with headroom go stored: a copy costs less than LZ4 on both ends.
/// Bigger frames, or any during congestion, compress while the content compresses;
/// incompressible content is rechecked with one chunk every `probeInterval` frames
public struct CompressionPolicy {
    public static let minRatio = 1.25
    public static let probeInterval = 30
    /// Frames treated as congested after the send queue was seen full
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

    /// `queueWasFull`: the link held a frame back since the previous call
    public mutating func next(rawBytes: Int, queueWasFull: Bool) -> TilePacker.Compression {
        if queueWasFull { congested = CompressionPolicy.congestionFrames }
        let tooBig = Double(rawBytes) * 8 * 60 * CompressionPolicy.headroom > capacityBits
        guard tooBig || congested > 0 else { return .none }
        congested = max(0, congested - 1)
        if compressible { return .all }
        untilProbe -= 1
        return untilProbe <= 0 ? .firstChunk : .none
    }

    /// Bytes fed to and produced by LZ4 in the last frame
    public mutating func record(rawBytes: Int, wireBytes: Int) {
        guard rawBytes > 0 else { return }
        compressible = Double(rawBytes) >= Double(max(1, wireBytes)) * CompressionPolicy.minRatio
        if !compressible { untilProbe = CompressionPolicy.probeInterval }
    }
}
