import Foundation
import AfterscreenCore

/// Zero-copy tileFrame payload parts
/// Stored chunks slice the upload buffer
/// Compressed chunks share one pooled buffer
public final class TilePacker {
    public enum Compression {
        case none
        case all
        /// Probe: compress only the first chunk
        case firstChunk
    }

    public static let maxChunks = 8
    /// Smaller chunks are not worth a thread
    static let minChunkBytes = 256 << 10

    private let scratch: [UnsafeMutableRawPointer]
    private var frameIndex: UInt32 = 0

    public init() {
        scratch = (0..<TilePacker.maxChunks).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: max(1, LZ4.encodeScratchSize), alignment: 16)
        }
    }

    deinit { scratch.forEach { $0.deallocate() } }

    /// `parts` in payload order
    /// `lz4In`/`lz4Out`: bytes LZ4 was tried on and produced
    public func pack(_ frame: EncodedFrame, geometry: TileGeometry, compression: Compression)
        -> (parts: [Data], wireBytes: Int, lz4In: Int, lz4Out: Int) {
        let raw = frame.data
        guard !raw.isEmpty else {
            let header = TileFrame.header(frameIndex: frameIndex, geometry: geometry, runs: frame.runs, chunks: [])
            frameIndex &+= 1
            return ([header], header.count, 0, 0)
        }
        let count = min(TilePacker.maxChunks, max(1, raw.count / TilePacker.minChunkBytes))
        let step = (raw.count / count + 15) / 16 * 16
        let ranges = stride(from: 0, to: raw.count, by: step).map { $0..<min($0 + step, raw.count) }

        var chunks: [Data]
        var lz4Sizes = [Int](repeating: 0, count: ranges.count)
        let tried = compression == .all ? ranges.count : (compression == .firstChunk ? 1 : 0)
        if tried > 0 {
            var offsets: [Int] = []
            var total = 0
            for r in ranges.prefix(tried) {
                offsets.append(total)
                total += LZ4.bound(r.count)
            }
            let out = BufferPool.shared.data(capacity: total) { dst in
                raw.withUnsafeBytes { src in
                    lz4Sizes.withUnsafeMutableBufferPointer { sizes in
                        DispatchQueue.concurrentPerform(iterations: tried) { i in
                            sizes[i] = LZ4.encode(UnsafeRawBufferPointer(rebasing: src[ranges[i]]), into: dst + offsets[i],
                                                  capacity: LZ4.bound(ranges[i].count), scratch: scratch[i]) ?? 0
                        }
                    }
                }
                return total
            }
            chunks = ranges.indices.map { i in
                lz4Sizes[i] > 0 ? out[offsets[i]..<(offsets[i] + lz4Sizes[i])] : raw[ranges[i]]
            }
        } else {
            chunks = ranges.map { raw[$0] }
        }
        let header = TileFrame.header(frameIndex: frameIndex, geometry: geometry, runs: frame.runs,
                                      chunks: ranges.indices.map { (ranges[$0].count, lz4Sizes[$0]) })
        frameIndex &+= 1
        let lz4In = ranges.prefix(tried).reduce(0) { $0 + $1.count }
        let lz4Out = (0..<tried).reduce(0) { $0 + chunks[$1].count }
        return ([header] + chunks, chunks.reduce(header.count) { $0 + $1.count }, lz4In, lz4Out)
    }
}
