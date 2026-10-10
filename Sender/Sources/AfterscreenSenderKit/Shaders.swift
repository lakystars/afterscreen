import AfterscreenCore

/// Metal source compiled at runtime; keeps the package free of metallib build steps
enum Shaders {
    static let tileEncoder = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint width;
        uint height;
        uint blocksX;
        uint blocksY;
        uint tilesX;
        uint tileBlocks;
        uint tileCount;
        uint candidates;
    };

    """ + BC7.metalCommon + """

    // Nearest of the 16 palette entries per pixel, seeded by projection
    static inline uint fitIndices(thread const int3 *px, int3 e0, int3 e1, thread uchar *idx) {
        float3 d = float3(e1 - e0);
        float dd = dot(d, d);
        uint err = 0;
        for (int i = 0; i < 16; i++) {
            int guess = dd > 0.0 ? clamp(int(round(dot(float3(px[i] - e0), d) / dd * 15.0)), 0, 15) : 0;
            int best = guess;
            uint bestErr = 0xffffffffu;
            for (int k = max(guess - 1, 0); k <= min(guess + 1, 15); k++) {
                uint e = sq(interp(e0, e1, kWeights[k]) - px[i]);
                if (e < bestErr) { bestErr = e; best = k; }
            }
            idx[i] = uchar(best);
            err += bestErr;
        }
        return err;
    }

    // 4×4 ordered dither thresholds in (0, 1): a 10-bit capture keeps its in-between levels as a fixed pattern;
    // an 8-bit capture lands on whole levels and passes through unchanged
    constant float kBayer[16] = { 0.5/16, 8.5/16, 2.5/16, 10.5/16, 12.5/16, 4.5/16, 14.5/16, 6.5/16,
                                  3.5/16, 11.5/16, 1.5/16, 9.5/16, 15.5/16, 7.5/16, 13.5/16, 5.5/16 };

    // Pixels of block `blk` and its endpoints along the principal axis (power iteration)
    static void fitBlock(texture2d<float, access::read> src, uint2 blk, constant Params &p,
                         thread int3 *px, thread float3 &ep0, thread float3 &ep1) {
        float3 mean = 0.0;
        for (uint i = 0; i < 16; i++) {
            uint2 c = min(blk * 4 + uint2(i & 3u, i >> 2), uint2(p.width - 1, p.height - 1));
            // An 8-bit level read back as float can sit a hair below the whole number
            px[i] = int3(min(floor(saturate(src.read(c).rgb) * 255.0 + 0.0001 + kBayer[(c.y & 3u) * 4 + (c.x & 3u)]), 255.0));
            mean += float3(px[i]);
        }
        mean /= 16.0;
        float cxx = 0, cxy = 0, cxz = 0, cyy = 0, cyz = 0, czz = 0;
        for (uint i = 0; i < 16; i++) {
            float3 d = float3(px[i]) - mean;
            cxx += d.x * d.x; cxy += d.x * d.y; cxz += d.x * d.z;
            cyy += d.y * d.y; cyz += d.y * d.z; czz += d.z * d.z;
        }
        float3 axis = float3(0.577, 0.577, 0.577);
        for (int it = 0; it < 6; it++) {
            float3 n = float3(cxx * axis.x + cxy * axis.y + cxz * axis.z,
                              cxy * axis.x + cyy * axis.y + cyz * axis.z,
                              cxz * axis.x + cyz * axis.y + czz * axis.z);
            float len = length(n);
            if (len < 1e-6) break;
            axis = n / len;
        }
        float tmin = 0.0, tmax = 0.0;
        for (uint i = 0; i < 16; i++) {
            float t = dot(float3(px[i]) - mean, axis);
            tmin = min(tmin, t);
            tmax = max(tmax, t);
        }
        ep0 = clamp(mean + axis * tmin, 0.0, 255.0);
        ep1 = clamp(mean + axis * tmax, 0.0, 255.0);
    }

    // BC7 mode 6: the four p-bit combinations, lowest error wins
    static uint4 encodeBlock(texture2d<float, access::read> src, uint2 blk, constant Params &p) {
        int3 px[16];
        float3 ep0, ep1;
        fitBlock(src, blk, p, px, ep0, ep1);
        uint bestErr = 0xffffffffu;
        int3 bq0 = 0, bq1 = 0;
        uint bp0 = 0, bp1 = 0;
        uchar bidx[16];
        for (uint pb = 0; pb < 4; pb++) {
            uint p0 = pb & 1u, p1 = pb >> 1;
            int3 q0 = clamp(int3(round((ep0 - float(p0)) * 0.5)), 0, 127);
            int3 q1 = clamp(int3(round((ep1 - float(p1)) * 0.5)), 0, 127);
            uchar idx[16];
            uint err = fitIndices(px, q0 * 2 + int(p0), q1 * 2 + int(p1), idx);
            if (err < bestErr) {
                bestErr = err;
                bq0 = q0; bq1 = q1; bp0 = p0; bp1 = p1;
                for (int i = 0; i < 16; i++) bidx[i] = idx[i];
            }
        }
        return packMode6(bq0, bq1, bp0, bp1, bidx);
    }

    static inline uint pack565(float3 c) {
        uint3 q = uint3(round(saturate(c / 255.0) * float3(31.0, 63.0, 31.0)));
        return (q.x << 11) | (q.y << 5) | q.z;
    }

    constant float kBC1Weight[4] = {0.0, 1.0, 21.0 / 64.0, 43.0 / 64.0};

    // Best of the four palette entries per pixel; returns the squared error
    static uint fitBC1(thread const int3 *px, uint c0, uint c1, thread uint &bits) {
        int3 e0 = unpack565(c0), e1 = unpack565(c1);
        int3 pal[4] = { e0, e1, interp(e0, e1, 21), interp(e0, e1, 43) };
        uint err = 0;
        bits = 0;
        for (uint i = 0; i < 16; i++) {
            uint best = 0, bestErr = 0xffffffffu;
            for (uint k = 0; k < 4; k++) {
                uint e = sq(pal[k] - px[i]);
                if (e < bestErr) { bestErr = e; best = k; }
            }
            bits |= best << (2 * i);
            err += bestErr;
        }
        return err;
    }

    // Endpoints ordered c0 ≥ c1 (equal: one colour, indices 0), fitted indices, squared error
    static uint3 orderBC1(uint c0, uint c1, thread const int3 *px) {
        if (c0 < c1) { uint t = c0; c0 = c1; c1 = t; }
        uint bits = 0;
        uint err = c0 == c1 ? 0xffffffffu : fitBC1(px, c0, c1, bits);
        return uint3(c0 | (c1 << 16), bits, err);
    }

    // BC1-style block: two 565 endpoints (c0 > c1) and 2-bit indices for c0, c1, 21/64 and 43/64,
    // the weights the receiver transcodes with. Principal-axis endpoints, then one least-squares refit
    static uint2 encodeBC1(texture2d<float, access::read> src, uint2 blk, constant Params &p) {
        int3 px[16];
        float3 ep0, ep1;
        fitBlock(src, blk, p, px, ep0, ep1);
        uint3 first = orderBC1(pack565(ep1), pack565(ep0), px);
        if (first.z == 0xffffffffu) return first.xy;
        uint bits = first.y;

        float aa = 0, ab = 0, bb = 0;
        float3 ax = 0.0, bx = 0.0;
        for (uint i = 0; i < 16; i++) {
            float w = kBC1Weight[(bits >> (2 * i)) & 3u];
            aa += (1 - w) * (1 - w); ab += (1 - w) * w; bb += w * w;
            ax += (1 - w) * float3(px[i]); bx += w * float3(px[i]);
        }
        float det = aa * bb - ab * ab;
        if (det < 1e-3) return first.xy;
        uint3 refit = orderBC1(pack565((ax * bb - bx * ab) / det), pack565((bx * aa - ax * ab) / det), px);
        return refit.z < first.z ? refit.xy : first.xy;
    }

    // Grid (tileBlocks, tileBlocks, candidates): one thread per block of each candidate tile, tile-major output
    kernel void bc7Encode(texture2d<float, access::read> src [[texture(0)]],
                          device uint4 *out [[buffer(0)]],
                          constant Params &p [[buffer(1)]],
                          device const uint *tiles [[buffer(2)]],
                          uint3 gid [[thread_position_in_grid]]) {
        uint tile = tiles[gid.z];
        uint2 blk = uint2((tile % p.tilesX) * p.tileBlocks + gid.x, (tile / p.tilesX) * p.tileBlocks + gid.y);
        if (blk.x >= p.blocksX || blk.y >= p.blocksY) return;
        out[tile * p.tileBlocks * p.tileBlocks + gid.y * p.tileBlocks + gid.x] = encodeBlock(src, blk, p);
    }

    // One thread per candidate tile; flags tiles whose blocks differ from the reference
    kernel void tileDiff(device const uint4 *cur [[buffer(0)]],
                         device const uint4 *ref [[buffer(1)]],
                         device uint *dirty [[buffer(2)]],
                         constant Params &p [[buffer(3)]],
                         device const uint *tiles [[buffer(4)]],
                         uint t [[thread_position_in_grid]]) {
        if (t >= p.candidates) return;
        uint tile = tiles[t];
        uint n = p.tileBlocks * p.tileBlocks;
        uint base = tile * n;
        uint d = 0;
        for (uint i = 0; i < n; i++) {
            if (any(cur[base + i] != ref[base + i])) { d = 1; break; }
        }
        dirty[tile] = d;
    }

    struct TileEntry {
        uint tile;
        uint outBase;  // in 8-byte units
        uint runWidth; // in blocks
        uint mode;     // 0 = BC7 from cur, 1 = BC7 from ref, 2 = BC1 from the texture, 3 = reference only
    };

    // One threadgroup per tile: writes its blocks in run order (row-major per run).
    // Modes 0, 2 and 3 also copy the new BC7 encoding into the reference
    kernel void tileGather(texture2d<float, access::read> src [[texture(0)]],
                           device const uint4 *cur [[buffer(0)]],
                           device uint4 *ref [[buffer(1)]],
                           device uint2 *out [[buffer(2)]],
                           device const TileEntry *table [[buffer(3)]],
                           constant Params &p [[buffer(4)]],
                           uint3 gid [[thread_position_in_grid]]) {
        TileEntry e = table[gid.z];
        uint2 blk = uint2((e.tile % p.tilesX) * p.tileBlocks + gid.x, (e.tile / p.tilesX) * p.tileBlocks + gid.y);
        if (blk.x >= p.blocksX || blk.y >= p.blocksY) return;
        uint slot = e.tile * p.tileBlocks * p.tileBlocks + gid.y * p.tileBlocks + gid.x;
        if (e.mode == 3u) {
            ref[slot] = cur[slot];
            return;
        }
        uint i = gid.y * e.runWidth + gid.x;
        if (e.mode == 2u) {
            ref[slot] = cur[slot];
            out[e.outBase + i] = encodeBC1(src, blk, p);
            return;
        }
        uint4 b = e.mode == 1u ? ref[slot] : cur[slot];
        if (e.mode == 0u) ref[slot] = b;
        out[e.outBase + 2 * i] = b.xy;
        out[e.outBase + 2 * i + 1] = b.zw;
    }
    """
}
