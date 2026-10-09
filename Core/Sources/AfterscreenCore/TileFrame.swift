import Compression
import Foundation

/// Stream split into square tiles of BC7 blocks; edge tiles are clipped
public struct TileGeometry: Equatable {
    public let width: Int
    public let height: Int
    public let tileBlocks: Int

    public init(width: Int, height: Int, tileBlocks: Int = 16) {
        self.width = width
        self.height = height
        self.tileBlocks = tileBlocks
    }

    public var tilePixels: Int { tileBlocks * 4 }
    public var blocksX: Int { (width + 3) / 4 }
    public var blocksY: Int { (height + 3) / 4 }
    public var tilesX: Int { (width + tilePixels - 1) / tilePixels }
    public var tilesY: Int { (height + tilePixels - 1) / tilePixels }
    public var tileCount: Int { tilesX * tilesY }
    public var tileBytes: Int { tileBlocks * tileBlocks * BC7.blockBytes }
}

/// Block encoding of a run
public enum TileFormat: UInt8 {
    case bc7 = 0
    /// 8 bytes per block, sent for tiles in motion; receivers transcode it to BC7
    case bc1 = 1
    /// No data: the tiles show the video layer until a BC7 or BC1 run replaces them
    case video = 2

    public var blockBytes: Int {
        switch self {
        case .bc7: return 16
        case .bc1: return 8
        case .video: return 0
        }
    }
}

/// Span of consecutive tiles in one tile row; its data is the covered blocks, row-major
public struct TileRun: Equatable {
    public var row: Int
    public var first: Int
    public var count: Int
    public var format: TileFormat

    public init(row: Int, first: Int, count: Int, format: TileFormat = .bc7) {
        self.row = row
        self.first = first
        self.count = count
        self.format = format
    }

    /// Covered blocks, clipped to the stream
    public func blocks(in g: TileGeometry) -> (w: Int, h: Int) {
        (min(count * g.tileBlocks, g.blocksX - first * g.tileBlocks), min(g.tileBlocks, g.blocksY - row * g.tileBlocks))
    }

    public func bytes(in g: TileGeometry) -> Int {
        let b = blocks(in: g)
        return b.w * b.h * format.blockBytes
    }

    public func origin(in g: TileGeometry) -> (x: Int, y: Int) {
        (first * g.tilePixels, row * g.tilePixels)
    }

    public func size(in g: TileGeometry) -> (w: Int, h: Int) {
        let b = blocks(in: g)
        return (b.w * 4, b.h * 4)
    }

    /// Runs of marked tiles, row by row: mark 0 = unchanged, else `TileFormat` raw value + 1.
    /// BC7 runs come before BC1 runs, as the wire format requires; video runs last
    public static func runs(marks: UnsafeBufferPointer<UInt32>, geometry g: TileGeometry) -> [TileRun] {
        var bc7: [TileRun] = [], bc1: [TileRun] = [], video: [TileRun] = []
        for row in 0..<g.tilesY {
            let base = row * g.tilesX
            var x = 0
            while x < g.tilesX {
                let mark = marks[base + x]
                guard mark != 0, let format = TileFormat(rawValue: UInt8(truncatingIfNeeded: mark - 1)) else {
                    x += 1
                    continue
                }
                let first = x
                while x < g.tilesX && marks[base + x] == mark { x += 1 }
                let run = TileRun(row: row, first: first, count: x - first, format: format)
                switch format {
                case .bc7: bc7.append(run)
                case .bc1: bc1.append(run)
                case .video: video.append(run)
                }
            }
        }
        return bc7 + bc1 + video
    }
}

/// tileFrame payload: u32 frame, u16 width, u16 height, u8 tileBlocks, u8 chunkCount, u16 runCount,
/// runCount × (u16 row, u16 first, u16 count, u8 format, u8 0), chunkCount × (u32 rawSize, u32 lz4Size; 0 = stored),
/// zero padding to 16 bytes, then chunk data.
/// The raw stream is every run's blocks in run order; chunks split it for parallel (de)compression.
/// BC7 runs come first, so BC7 data stays 16-byte aligned and BC1 blocks end the stream.
/// Video runs carry no data. A frame without runs only presents (the hybrid path's video picture)
public struct TileFrame {
    public struct Chunk {
        public let rawOffset: Int
        public let rawSize: Int
        /// Index range in `payload`
        public let data: Range<Int>
        public let compressed: Bool
    }

    public static let maxChunks = 64
    public let frameIndex: UInt32
    public let geometry: TileGeometry
    public let runs: [TileRun]
    public let chunks: [Chunk]
    public let payload: Data
    public let rawBytes: Int
    /// Offset of the first chunk's data from the payload start; 16-byte aligned
    public let dataOffset: Int

    public static func header(frameIndex: UInt32, geometry g: TileGeometry, runs: [TileRun],
                              chunks: [(rawSize: Int, lz4Size: Int)]) -> Data {
        var w = ByteWriter(capacity: 32 + runs.count * 8 + chunks.count * 8)
        w.u32(frameIndex)
        w.u16(UInt16(g.width))
        w.u16(UInt16(g.height))
        w.u8(UInt8(g.tileBlocks))
        w.u8(UInt8(chunks.count))
        w.u16(UInt16(runs.count))
        for r in runs {
            w.u16(UInt16(r.row))
            w.u16(UInt16(r.first))
            w.u16(UInt16(r.count))
            w.u8(r.format.rawValue)
            w.u8(0)
        }
        for c in chunks {
            w.u32(UInt32(c.rawSize))
            w.u32(UInt32(c.lz4Size))
        }
        while w.data.count % 16 != 0 { w.u8(0) }
        return w.data
    }

    /// Validates the layout against the payload; `expecting` rejects other geometries
    public init(payload: Data, expecting expected: TileGeometry? = nil) throws {
        var r = ByteReader(payload)
        frameIndex = try r.u32()
        let width = Int(try r.u16()), height = Int(try r.u16())
        let tileBlocks = Int(try r.u8()), chunkCount = Int(try r.u8()), runCount = Int(try r.u16())
        guard width > 0, height > 0, width % 4 == 0, height % 4 == 0, (1...64).contains(tileBlocks),
              chunkCount <= TileFrame.maxChunks else {
            throw FramingError.invalid("tile frame header")
        }
        let g = TileGeometry(width: width, height: height, tileBlocks: tileBlocks)
        if let expected = expected, expected != g { throw FramingError.invalid("tile frame geometry") }
        guard runCount <= g.tileCount else { throw FramingError.invalid("tile run count") }

        var runs: [TileRun] = []
        runs.reserveCapacity(runCount)
        var runBytes = 0, runBlocks = 0
        for _ in 0..<runCount {
            let row = Int(try r.u16()), first = Int(try r.u16()), count = Int(try r.u16())
            guard let format = TileFormat(rawValue: try r.u8()), try r.u8() == 0 else { throw FramingError.invalid("tile run format") }
            let run = TileRun(row: row, first: first, count: count, format: format)
            guard run.row < g.tilesY, run.count > 0, run.first + run.count <= g.tilesX,
                  !(run.format == .bc7 && runs.last?.format == .bc1) else {
                throw FramingError.invalid("tile run")
            }
            let b = run.blocks(in: g)
            runBytes += run.bytes(in: g)
            if run.format != .video { runBlocks += b.w * b.h }
            runs.append(run)
        }
        // Repeated runs must not describe more blocks than one frame holds; the receiver sizes buffers by it
        guard runBlocks <= g.blocksX * g.blocksY else { throw FramingError.invalid("tile runs exceed the frame") }
        var sizes: [(raw: Int, lz4: Int)] = []
        for _ in 0..<chunkCount { sizes.append((Int(try r.u32()), Int(try r.u32()))) }

        let dataOffset = (r.position - payload.startIndex + 15) / 16 * 16
        var offset = payload.startIndex + dataOffset
        guard offset <= payload.endIndex else { throw FramingError.truncated }
        var chunks: [Chunk] = []
        var raw = 0
        for size in sizes {
            let length = size.lz4 == 0 ? size.raw : size.lz4
            guard length <= payload.endIndex - offset else { throw FramingError.truncated }
            chunks.append(Chunk(rawOffset: raw, rawSize: size.raw, data: offset..<(offset + length), compressed: size.lz4 != 0))
            raw += size.raw
            offset += length
        }
        guard raw == runBytes, offset == payload.endIndex else { throw FramingError.invalid("tile frame sizes") }
        geometry = g
        self.runs = runs
        self.chunks = chunks
        self.payload = payload
        self.dataOffset = dataOffset
        rawBytes = raw
    }

    /// Writes chunk `index` to `raw + rawOffset`
    public func decode(chunk index: Int, into raw: UnsafeMutableRawPointer, scratch: UnsafeMutableRawPointer? = nil) throws {
        let c = chunks[index]
        guard c.rawSize > 0 else { return }
        try payload.withUnsafeBytes { all in
            let src = UnsafeRawBufferPointer(rebasing: all[(c.data.lowerBound - payload.startIndex)..<(c.data.upperBound - payload.startIndex)])
            if c.compressed {
                try LZ4.decode(src, into: raw + c.rawOffset, rawSize: c.rawSize, scratch: scratch)
            } else {
                (raw + c.rawOffset).copyMemory(from: src.baseAddress!, byteCount: c.rawSize)
            }
        }
    }

    /// Raw-stream offset where the BC1 runs start, and how many BC1 blocks follow
    public var bc1Span: (offset: Int, blocks: Int) {
        var offset = 0, blocks = 0
        for run in runs {
            let b = run.blocks(in: geometry)
            switch run.format {
            case .bc7: offset += b.w * b.h * BC7.blockBytes
            case .bc1: blocks += b.w * b.h
            case .video: break
            }
        }
        return (offset, blocks)
    }

    /// Whole raw stream; for tests and tools
    public func decodeAll() throws -> Data {
        var out = Data(count: rawBytes)
        guard rawBytes > 0 else { return out }
        try out.withUnsafeMutableBytes { dst in
            for i in chunks.indices { try decode(chunk: i, into: dst.baseAddress!) }
        }
        return out
    }
}

/// Raw LZ4 blocks through Apple's Compression framework
public enum LZ4 {
    public static let encodeScratchSize = compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW)
    public static let decodeScratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW)

    /// Worst-case output size
    public static func bound(_ count: Int) -> Int { count + count / 255 + 16 }

    /// Output size, or nil when it would not be smaller than the input
    public static func encode(_ src: UnsafeRawBufferPointer, into dst: UnsafeMutableRawPointer, capacity: Int,
                              scratch: UnsafeMutableRawPointer? = nil) -> Int? {
        guard let base = src.baseAddress, src.count > 1 else { return nil }
        let n = compression_encode_buffer(dst.assumingMemoryBound(to: UInt8.self), min(capacity, src.count - 1),
                                          base.assumingMemoryBound(to: UInt8.self), src.count, scratch, COMPRESSION_LZ4_RAW)
        return n > 0 ? n : nil
    }

    public static func decode(_ src: UnsafeRawBufferPointer, into dst: UnsafeMutableRawPointer, rawSize: Int,
                              scratch: UnsafeMutableRawPointer? = nil) throws {
        guard rawSize > 0 else { return }
        guard let base = src.baseAddress, src.count > 0 else { throw FramingError.invalid("lz4 empty") }
        let n = compression_decode_buffer(dst.assumingMemoryBound(to: UInt8.self), rawSize,
                                          base.assumingMemoryBound(to: UInt8.self), src.count, scratch, COMPRESSION_LZ4_RAW)
        guard n == rawSize else { throw FramingError.invalid("lz4 size \(n) != \(rawSize)") }
    }
}
