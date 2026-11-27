namespace Afterscreen.Sender.Encode;

/// <summary>Mac <c>Shaders.tileEncoder</c> / <c>BC7.metalCommon</c> — BC7 mode-6 compute (cs_5_0).</summary>
internal static class Bc7EncodeHlsl
{
    /// <summary>Params cbuffer and the resources of the original (dense, on-demand) BC7 kernel.</summary>
    public const string Header = """
cbuffer Params : register(b0) {
    uint width;
    uint height;
    uint blocksX;
    uint blocksY;
    uint tilesX;
    uint tileBlocks;
    uint tileCount;
    uint candidates;
};

Texture2D<float4> src : register(t0);
StructuredBuffer<uint> tiles : register(t1);
RWStructuredBuffer<uint4> outBlocks : register(u0);
""";

    /// <summary>BC7 mode-6 block encoder (Mac Shaders.swift fitBlock/encodeBlock port); needs src, width and height.</summary>
    public const string Helpers = """
static const int kWeights[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};
static const float kBayer[16] = {
    0.5/16, 8.5/16, 2.5/16, 10.5/16, 12.5/16, 4.5/16, 14.5/16, 6.5/16,
    3.5/16, 11.5/16, 1.5/16, 9.5/16, 15.5/16, 7.5/16, 13.5/16, 5.5/16
};

void putBits(inout uint b0, inout uint b1, inout uint b2, inout uint b3, inout uint pos, uint v, uint n) {
    uint word = pos >> 5;
    uint shift = pos & 31u;
    uint chunk = v << shift;
    if (word == 0) b0 |= chunk;
    else if (word == 1) b1 |= chunk;
    else if (word == 2) b2 |= chunk;
    else b3 |= chunk;
    if (shift + n > 32u) {
        uint hi = v >> (32u - shift);
        if (word == 0) b1 |= hi;
        else if (word == 1) b2 |= hi;
        else if (word == 2) b3 |= hi;
    }
    pos += n;
}

int3 interp(int3 e0, int3 e1, int w) {
    return ((64 - w) * e0 + w * e1 + 32) >> 6;
}

uint sq(int3 c) {
    return (uint)(c.x * c.x + c.y * c.y + c.z * c.z);
}

uint4 packMode6(int3 q0, int3 q1, uint p0, uint p1, inout uint idx[16]) {
    if (idx[0] >= 8) {
        int3 tq = q0; q0 = q1; q1 = tq;
        uint tp = p0; p0 = p1; p1 = tp;
        [unroll] for (int i = 0; i < 16; i++) idx[i] = 15u - idx[i];
    }
    uint b0 = 0, b1 = 0, b2 = 0, b3 = 0, pos = 0;
    putBits(b0, b1, b2, b3, pos, 0x40u, 7);
    putBits(b0, b1, b2, b3, pos, (uint)q0.x, 7); putBits(b0, b1, b2, b3, pos, (uint)q1.x, 7);
    putBits(b0, b1, b2, b3, pos, (uint)q0.y, 7); putBits(b0, b1, b2, b3, pos, (uint)q1.y, 7);
    putBits(b0, b1, b2, b3, pos, (uint)q0.z, 7); putBits(b0, b1, b2, b3, pos, (uint)q1.z, 7);
    putBits(b0, b1, b2, b3, pos, 127u, 7); putBits(b0, b1, b2, b3, pos, 127u, 7);
    putBits(b0, b1, b2, b3, pos, p0, 1); putBits(b0, b1, b2, b3, pos, p1, 1);
    putBits(b0, b1, b2, b3, pos, idx[0], 3);
    [unroll] for (int j = 1; j < 16; j++) putBits(b0, b1, b2, b3, pos, idx[j], 4);
    return uint4(b0, b1, b2, b3);
}

uint fitIndices(in int3 px[16], int3 e0, int3 e1, out uint idx[16]) {
    float3 d = float3(e1 - e0);
    float dd = dot(d, d);
    uint err = 0;
    [unroll] for (int i = 0; i < 16; i++) {
        int guess = dd > 0.0 ? (int)clamp(round(dot(float3(px[i] - e0), d) / dd * 15.0), 0.0, 15.0) : 0;
        int best = guess;
        uint bestErr = 0xffffffffu;
        int k0 = max(guess - 1, 0);
        int k1 = min(guess + 1, 15);
        for (int k = k0; k <= k1; k++) {
            uint e = sq(interp(e0, e1, kWeights[k]) - px[i]);
            if (e < bestErr) { bestErr = e; best = k; }
        }
        idx[i] = (uint)best;
        err += bestErr;
    }
    return err;
}

void fitBlock(uint2 blk, out int3 px[16], out float3 ep0, out float3 ep1) {
    float3 mean = 0;
    [unroll] for (uint i = 0; i < 16; i++) {
        uint2 c = min(blk * 4 + uint2(i & 3u, i >> 2), uint2(width - 1, height - 1));
        float4 s = src.Load(int3(c, 0));
        float3 rgb = min(floor(saturate(s.rgb) * 255.0 + 0.0001 + kBayer[(c.y & 3u) * 4 + (c.x & 3u)]), 255.0);
        px[i] = int3(rgb);
        mean += rgb;
    }
    mean /= 16.0;
    float cxx = 0, cxy = 0, cxz = 0, cyy = 0, cyz = 0, czz = 0;
    [unroll] for (uint j = 0; j < 16; j++) {
        float3 d = float3(px[j]) - mean;
        cxx += d.x * d.x; cxy += d.x * d.y; cxz += d.x * d.z;
        cyy += d.y * d.y; cyz += d.y * d.z; czz += d.z * d.z;
    }
    float3 axis = float3(0.577, 0.577, 0.577);
    [unroll] for (int it = 0; it < 6; it++) {
        float3 n = float3(cxx * axis.x + cxy * axis.y + cxz * axis.z,
                          cxy * axis.x + cyy * axis.y + cyz * axis.z,
                          cxz * axis.x + cyz * axis.y + czz * axis.z);
        float len = length(n);
        if (len < 1e-6) break;
        axis = n / len;
    }
    float tmin = 0, tmax = 0;
    [unroll] for (uint k = 0; k < 16; k++) {
        float t = dot(float3(px[k]) - mean, axis);
        tmin = min(tmin, t);
        tmax = max(tmax, t);
    }
    ep0 = clamp(mean + axis * tmin, 0.0, 255.0);
    ep1 = clamp(mean + axis * tmax, 0.0, 255.0);
}

uint4 encodeBlock(uint2 blk) {
    int3 px[16];
    float3 ep0, ep1;
    fitBlock(blk, px, ep0, ep1);
    uint bestErr = 0xffffffffu;
    int3 bq0 = 0, bq1 = 0;
    uint bp0 = 0, bp1 = 0;
    uint bidx[16];
    [unroll] for (uint i = 0; i < 16; i++) bidx[i] = 0;
    for (uint pb = 0; pb < 4; pb++) {
        uint p0 = pb & 1u, p1 = pb >> 1;
        int3 q0 = clamp(int3(round((ep0 - float(p0)) * 0.5)), 0, 127);
        int3 q1 = clamp(int3(round((ep1 - float(p1)) * 0.5)), 0, 127);
        uint idx[16];
        uint err = fitIndices(px, q0 * 2 + (int)p0, q1 * 2 + (int)p1, idx);
        if (err < bestErr) {
            bestErr = err;
            bq0 = q0; bq1 = q1; bp0 = p0; bp1 = p1;
            [unroll] for (int i = 0; i < 16; i++) bidx[i] = idx[i];
        }
    }
    return packMode6(bq0, bq1, bp0, bp1, bidx);
}
""";

    /// <summary>The original kernel: dense output per candidate (used by D3dTileEncoder).</summary>
    public const string LegacyKernel = """
// Dense output: outBlocks[candidateIndex * tileBlocks^2 + local] — not full-frame sparse.
[numthreads(8, 8, 1)]
void bc7Encode(uint3 id : SV_DispatchThreadID) {
    if (id.z >= candidates || id.x >= tileBlocks || id.y >= tileBlocks) return;
    uint tile = tiles[id.z];
    uint2 blk = uint2((tile % tilesX) * tileBlocks + id.x, (tile / tilesX) * tileBlocks + id.y);
    if (blk.x >= blocksX || blk.y >= blocksY) return;
    outBlocks[id.z * tileBlocks * tileBlocks + id.y * tileBlocks + id.x] = encodeBlock(blk);
}
""";

    public const string Source = Header + "\n" + Helpers + "\n" + LegacyKernel;
}
