import Foundation

/// BC7 reference codec for mode 6, the sender's only mode
/// Other modes decode to magenta to expose mismatches
public enum BC7 {
    public static let blockBytes = 16
    public static let weights4: [Int] = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]

    /// 4x4 block → 64 bytes RGBA, row-major
    public static func decodeBlock(_ block: UnsafeRawBufferPointer) -> [UInt8] {
        precondition(block.count >= blockBytes)
        var bits = BitReader(block)
        guard bits.read(7) == 0x40 else {
            return [UInt8](repeating: 0, count: 64).enumerated().map { i, _ in [255, 0, 255, 255][i % 4] }
        }
        var raw = [[Int]](repeating: [0, 0], count: 4)
        for c in 0..<4 {
            raw[c][0] = bits.read(7)
            raw[c][1] = bits.read(7)
        }
        let p0 = bits.read(1), p1 = bits.read(1)
        var e0 = [Int](repeating: 0, count: 4), e1 = e0
        for c in 0..<4 {
            e0[c] = raw[c][0] << 1 | p0
            e1[c] = raw[c][1] << 1 | p1
        }
        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let index = bits.read(i == 0 ? 3 : 4)
            let w = weights4[index]
            for c in 0..<4 {
                out[i * 4 + c] = UInt8(((64 - w) * e0[c] + w * e1[c] + 32) >> 6)
            }
        }
        return out
    }

    /// Endpoint components are 7-bit; index 0 must be < 8
    public static func makeMode6(e0: (UInt8, UInt8, UInt8, UInt8), e1: (UInt8, UInt8, UInt8, UInt8),
                                 p0: UInt8, p1: UInt8, indices: [UInt8]) -> [UInt8] {
        precondition(indices.count == 16 && indices[0] < 8)
        var bits = BitWriter()
        bits.write(0x40, 7)
        let a = [e0.0, e0.1, e0.2, e0.3], b = [e1.0, e1.1, e1.2, e1.3]
        for c in 0..<4 {
            bits.write(Int(a[c] & 0x7F), 7)
            bits.write(Int(b[c] & 0x7F), 7)
        }
        bits.write(Int(p0 & 1), 1)
        bits.write(Int(p1 & 1), 1)
        for i in 0..<16 {
            bits.write(Int(indices[i]), i == 0 ? 3 : 4)
        }
        return bits.bytes
    }
}

private struct BitReader {
    let block: UnsafeRawBufferPointer
    var position = 0

    init(_ block: UnsafeRawBufferPointer) { self.block = block }

    mutating func read(_ count: Int) -> Int {
        var v = 0
        for i in 0..<count {
            let bit = (Int(block[(position + i) >> 3]) >> ((position + i) & 7)) & 1
            v |= bit << i
        }
        position += count
        return v
    }
}

private struct BitWriter {
    var bytes = [UInt8](repeating: 0, count: 16)
    var position = 0

    mutating func write(_ value: Int, _ count: Int) {
        for i in 0..<count where (value >> i) & 1 == 1 {
            bytes[(position + i) >> 3] |= UInt8(1 << ((position + i) & 7))
        }
        position += count
    }
}

public extension BC7 {
    /// Metal helpers shared by sender encoder and receiver BC1 transcoder
    static let metalCommon = """
    constant int kWeights[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};

    // `v` fits in `n` bits; splits across word boundaries
    static inline void putBits(thread uint4 &b, thread uint &pos, uint v, uint n) {
        uint word = pos >> 5, shift = pos & 31u;
        b[word] |= v << shift;
        if (shift + n > 32u) b[word + 1] |= v >> (32u - shift);
        pos += n;
    }

    static inline int3 interp(int3 e0, int3 e1, int w) {
        return ((64 - w) * e0 + w * e1 + 32) >> 6;
    }

    static inline uint sq(int3 c) {
        return uint(c.x * c.x + c.y * c.y + c.z * c.z);
    }

    static inline int3 unpack565(uint v) {
        int r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
        return int3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
    }

    // Mode 6 block: 7-bit endpoints, p-bits, 4-bit indices, opaque alpha
    // Anchor index 0 is stored in 3 bits
    // Anchor >= 8: swap endpoints, invert indices
    static uint4 packMode6(int3 q0, int3 q1, uint p0, uint p1, thread uchar *idx) {
        if (idx[0] >= 8) {
            int3 tq = q0; q0 = q1; q1 = tq;
            uint tp = p0; p0 = p1; p1 = tp;
            for (int i = 0; i < 16; i++) idx[i] = uchar(15 - idx[i]);
        }
        uint4 b = uint4(0);
        uint pos = 0;
        putBits(b, pos, 0x40u, 7);
        putBits(b, pos, uint(q0.x), 7); putBits(b, pos, uint(q1.x), 7);
        putBits(b, pos, uint(q0.y), 7); putBits(b, pos, uint(q1.y), 7);
        putBits(b, pos, uint(q0.z), 7); putBits(b, pos, uint(q1.z), 7);
        putBits(b, pos, 127u, 7); putBits(b, pos, 127u, 7);
        putBits(b, pos, p0, 1); putBits(b, pos, p1, 1);
        putBits(b, pos, uint(idx[0]), 3);
        for (int i = 1; i < 16; i++) putBits(b, pos, uint(idx[i]), 4);
        return b;
    }
    """
}
