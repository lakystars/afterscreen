import XCTest
@testable import AfterscreenCore

final class TileFrameTests: XCTestCase {
    func testGeometry5K() {
        let g = TileGeometry(width: 5120, height: 2880)
        XCTAssertEqual(g.tilesX, 80)
        XCTAssertEqual(g.tilesY, 45)
        XCTAssertEqual(g.tileCount, 3600)
        XCTAssertEqual(g.blocksX, 1280)
        XCTAssertEqual(g.blocksY, 720)
        XCTAssertEqual(g.tileBytes, 4096)
    }

    func testGeometryPartialLastRow1440p() {
        let g = TileGeometry(width: 2560, height: 1440)
        XCTAssertEqual(g.tilesX, 40)
        XCTAssertEqual(g.tilesY, 23)
        let last = TileRun(row: 22, first: 39, count: 1)
        XCTAssertEqual(last.origin(in: g).x, 39 * 64)
        XCTAssertEqual(last.origin(in: g).y, 22 * 64)
        XCTAssertEqual(last.size(in: g).w, 64)
        XCTAssertEqual(last.size(in: g).h, 32)
        XCTAssertEqual(TileRun(row: 0, first: 0, count: 1).size(in: g).h, 64)
    }

    func testGeometryPartialLastRow1080p() {
        let g = TileGeometry(width: 1920, height: 1080)
        XCTAssertEqual(g.tilesX, 30)
        XCTAssertEqual(g.tilesY, 17)
        XCTAssertEqual(TileRun(row: 16, first: 29, count: 1).size(in: g).h, 56)
    }

    // MARK: - Runs

    func testRunsSplitAtCleanTiles() {
        let g = TileGeometry(width: 256, height: 192)
        let flags: [UInt32] = [1, 1, 0, 1,
                               0, 0, 0, 0,
                               1, 1, 1, 1]
        let runs = flags.withUnsafeBufferPointer { TileRun.runs(marks: $0, geometry: g) }
        XCTAssertEqual(runs, [TileRun(row: 0, first: 0, count: 2), TileRun(row: 0, first: 3, count: 1), TileRun(row: 2, first: 0, count: 4)])
    }

    func testRunsSplitAtFormatChangesWithBC7First() {
        let g = TileGeometry(width: 256, height: 128)
        let marks: [UInt32] = [2, 2, 1, 1,
                               0, 2, 1, 0]
        let runs = marks.withUnsafeBufferPointer { TileRun.runs(marks: $0, geometry: g) }
        XCTAssertEqual(runs, [TileRun(row: 0, first: 2, count: 2), TileRun(row: 1, first: 2, count: 1),
                              TileRun(row: 0, first: 0, count: 2, format: .bc1), TileRun(row: 1, first: 1, count: 1, format: .bc1)])
        XCTAssertEqual(runs[2].bytes(in: g), runs[2].count * 16 * 16 * 8)
    }

    func testVideoRunsComeLastAndCarryNoData() {
        let g = TileGeometry(width: 256, height: 128)
        let marks: [UInt32] = [3, 3, 1, 2,
                               0, 3, 0, 0]
        let runs = marks.withUnsafeBufferPointer { TileRun.runs(marks: $0, geometry: g) }
        XCTAssertEqual(runs, [TileRun(row: 0, first: 2, count: 1), TileRun(row: 0, first: 3, count: 1, format: .bc1),
                              TileRun(row: 0, first: 0, count: 2, format: .video), TileRun(row: 1, first: 1, count: 1, format: .video)])
        XCTAssertEqual(runs[2].bytes(in: g), 0)
    }

    func testRunClipsAtStreamEdge() {
        let g = TileGeometry(width: 2600, height: 1440)
        let run = TileRun(row: 22, first: 39, count: 2)
        XCTAssertEqual(run.blocks(in: g).w, 16 + 10)
        XCTAssertEqual(run.blocks(in: g).h, 8)
        XCTAssertEqual(run.bytes(in: g), 26 * 8 * 16)
        XCTAssertEqual(run.origin(in: g).x, 39 * 64)
        XCTAssertEqual(run.origin(in: g).y, 22 * 64)
        XCTAssertEqual(run.size(in: g).w, 64 + 40)
        XCTAssertEqual(run.size(in: g).h, 32)
    }

    // MARK: - Frame layout

    private let g = TileGeometry(width: 256, height: 192)
    private let runs = [TileRun(row: 0, first: 1, count: 2), TileRun(row: 2, first: 0, count: 1)]

    private func raw() -> Data {
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        return Data((0..<size).map { UInt8(($0 / 4096) * 3 + ($0 % 16 == 0 ? 1 : 0)) })
    }

    /// First half LZ4, second half stored
    private func payload(_ raw: Data) -> Data {
        let half = raw.count / 2 / 16 * 16
        let a = raw.prefix(half), b = raw.suffix(from: half)
        var lz4 = Data(count: LZ4.bound(a.count))
        let n = lz4.withUnsafeMutableBytes { dst in a.withUnsafeBytes { LZ4.encode($0, into: dst.baseAddress!, capacity: dst.count) } }!
        lz4.count = n
        return TileFrame.header(frameIndex: 7, geometry: g, runs: runs, chunks: [(a.count, n), (b.count, 0)]) + lz4 + b
    }

    func testLayoutRoundTripWithCompressedAndStoredChunks() throws {
        let raw = raw()
        let frame = try TileFrame(payload: payload(raw), expecting: g)
        XCTAssertEqual(frame.frameIndex, 7)
        XCTAssertEqual(frame.runs, runs)
        XCTAssertEqual(frame.rawBytes, raw.count)
        XCTAssertEqual(frame.chunks.map(\.compressed), [true, false])
        XCTAssertEqual(try frame.decodeAll(), raw)
    }

    func testLayoutRejectsAnotherGeometry() {
        XCTAssertThrowsError(try TileFrame(payload: payload(raw()), expecting: TileGeometry(width: 512, height: 192)))
    }

    func testLayoutRejectsRunsOutsideTheStream() {
        for bad in [TileRun(row: 3, first: 0, count: 1), TileRun(row: 0, first: 3, count: 2), TileRun(row: 0, first: 0, count: 0)] {
            let size = max(16, bad.bytes(in: g))
            let p = TileFrame.header(frameIndex: 0, geometry: g, runs: [bad], chunks: [(size, 0)]) + Data(count: size)
            XCTAssertThrowsError(try TileFrame(payload: p, expecting: g), "\(bad)")
        }
    }

    func testLayoutRejectsSizeMismatchOverrunAndTrailingBytes() {
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        let short = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size - 16, 0)]) + Data(count: size - 16)
        XCTAssertThrowsError(try TileFrame(payload: short, expecting: g))
        let overrun = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + Data(count: size - 1)
        XCTAssertThrowsError(try TileFrame(payload: overrun, expecting: g))
        let trailing = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + Data(count: size + 1)
        XCTAssertThrowsError(try TileFrame(payload: trailing, expecting: g))
        XCTAssertThrowsError(try TileFrame(payload: Data([1, 2, 3]), expecting: g))
    }

    func testLayoutRejectsMoreDataThanOneFrame() {
        let full = TileRun(row: 0, first: 0, count: 4)
        let runs = [TileRun](repeating: full, count: 4)
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        let p = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + Data(count: size)
        XCTAssertThrowsError(try TileFrame(payload: p, expecting: g))
    }

    func testLayoutWithBC1RunsAndTheirSpan() throws {
        let runs = [TileRun(row: 0, first: 0, count: 1), TileRun(row: 1, first: 0, count: 2, format: .bc1)]
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        let raw = Data((0..<size).map { UInt8($0 % 251) })
        let frame = try TileFrame(payload: TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + raw, expecting: g)
        XCTAssertEqual(frame.runs, runs)
        XCTAssertEqual(frame.bc1Span.offset, 16 * 16 * 16)
        XCTAssertEqual(frame.bc1Span.blocks, 2 * 16 * 16)
        XCTAssertEqual(try frame.decodeAll(), raw)
    }

    func testLayoutWithVideoRunsHasDataOnlyForTileRuns() throws {
        let runs = [TileRun(row: 0, first: 0, count: 1), TileRun(row: 1, first: 0, count: 2, format: .bc1),
                    TileRun(row: 0, first: 1, count: 3, format: .video), TileRun(row: 2, first: 0, count: 4, format: .video)]
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        XCTAssertEqual(size, 16 * 16 * 16 + 2 * 16 * 16 * 8)
        let raw = Data((0..<size).map { UInt8($0 % 251) })
        let frame = try TileFrame(payload: TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + raw, expecting: g)
        XCTAssertEqual(frame.runs, runs)
        XCTAssertEqual(frame.bc1Span.offset, 16 * 16 * 16)
        XCTAssertEqual(frame.bc1Span.blocks, 2 * 16 * 16)
        XCTAssertEqual(try frame.decodeAll(), raw)
    }

    func testFrameWithoutRunsOnlyPresents() throws {
        let frame = try TileFrame(payload: TileFrame.header(frameIndex: 0, geometry: g, runs: [], chunks: []), expecting: g)
        XCTAssertTrue(frame.runs.isEmpty)
        XCTAssertEqual(frame.rawBytes, 0)
    }

    func testLayoutRejectsBC7AfterBC1AndUnknownFormats() {
        let misordered = [TileRun(row: 0, first: 0, count: 1, format: .bc1), TileRun(row: 1, first: 0, count: 1)]
        let size = misordered.reduce(0) { $0 + $1.bytes(in: g) }
        XCTAssertThrowsError(try TileFrame(payload: TileFrame.header(frameIndex: 0, geometry: g, runs: misordered, chunks: [(size, 0)])
            + Data(count: size), expecting: g))
        var bad = TileFrame.header(frameIndex: 0, geometry: g, runs: [TileRun(row: 0, first: 0, count: 1)], chunks: [(4096, 0)]) + Data(count: 4096)
        bad[bad.startIndex + 18] = 7 // format byte of the first run (12-byte header + 6)
        XCTAssertThrowsError(try TileFrame(payload: bad, expecting: g))
    }

    func testLayoutRejectsMoreBlocksThanOneFrame() {
        let row = TileRun(row: 0, first: 0, count: 4, format: .bc1)
        let runs = [TileRun](repeating: row, count: 4) // 4 rows of BC1 on a 3-row frame: bytes fit, blocks do not
        let size = runs.reduce(0) { $0 + $1.bytes(in: g) }
        XCTAssertLessThanOrEqual(size, g.blocksX * g.blocksY * 16)
        let p = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(size, 0)]) + Data(count: size)
        XCTAssertThrowsError(try TileFrame(payload: p, expecting: g))
    }

    func testCorruptLZ4FailsToDecode() throws {
        var p = payload(raw())
        let header = TileFrame.header(frameIndex: 0, geometry: g, runs: runs, chunks: [(0, 0), (0, 0)]).count
        p[p.startIndex + header + 3] ^= 0xFF
        p[p.startIndex + header] = 0xF0
        let frame = try TileFrame(payload: p, expecting: g)
        XCTAssertThrowsError(try frame.decodeAll())
    }
}
