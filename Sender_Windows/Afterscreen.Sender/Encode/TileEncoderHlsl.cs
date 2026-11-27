namespace Afterscreen.Sender.Encode;

/// <summary>
/// HLSL (cs_5_0) for <see cref="GpuTileEncoder"/>, a port of the Mac <c>Shaders.tileEncoder</c> kernels:
/// <c>tileDiff</c> (here on pixels against a reference texture) and <c>tileGather</c> (BC7 / BC1 written in run order).
/// The BC7 block encoder itself is shared with <see cref="Bc7EncodeHlsl"/>.
/// </summary>
internal static class TileEncoderHlsl
{
    /// <summary>Params cbuffer and the frame texture; same field order as the Mac <c>Params</c> struct.</summary>
    public const string Header = """
cbuffer Params : register(b0) {
    uint width;
    uint height;
    uint blocksX;
    uint blocksY;
    uint tilesX;
    uint tileBlocks;
    uint tileCount;
    uint candidates;   // tiles in the candidate list (diff) or entries in the gather table
};

Texture2D<float4> src : register(t0);
""";

    /// <summary>BC1-style block (Mac encodeBC1): two 565 endpoints, 2-bit indices, weights 0, 1, 21/64, 43/64.</summary>
    public const string Bc1 = """
uint pack565(float3 c) {
    uint3 q = (uint3)round(saturate(c / 255.0) * float3(31.0, 63.0, 31.0));
    return (q.x << 11) | (q.y << 5) | q.z;
}

int3 unpack565(uint v) {
    int r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
    return int3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
}

static const float kBC1Weight[4] = {0.0, 1.0, 21.0 / 64.0, 43.0 / 64.0};

// Best of 4 palette entries per pixel; returns squared error
uint fitBC1(in int3 px[16], uint c0, uint c1, out uint bits) {
    int3 e0 = unpack565(c0), e1 = unpack565(c1);
    int3 pal[4] = { e0, e1, interp(e0, e1, 21), interp(e0, e1, 43) };
    uint err = 0;
    bits = 0;
    [unroll] for (uint i = 0; i < 16; i++) {
        uint best = 0, bestErr = 0xffffffffu;
        [unroll] for (uint k = 0; k < 4; k++) {
            uint e = sq(pal[k] - px[i]);
            if (e < bestErr) { bestErr = e; best = k; }
        }
        bits |= best << (2 * i);
        err += bestErr;
    }
    return err;
}

// Endpoints ordered c0 >= c1, fitted indices, squared error. Equal endpoints: one colour, indices 0.
uint3 orderBC1(uint c0, uint c1, in int3 px[16]) {
    if (c0 < c1) { uint t = c0; c0 = c1; c1 = t; }
    uint bits = 0;
    uint err = (c0 == c1) ? 0xffffffffu : fitBC1(px, c0, c1, bits);
    return uint3(c0 | (c1 << 16), bits, err);
}

// Principal-axis endpoints, then one least-squares refit
uint2 encodeBC1(uint2 blk) {
    int3 px[16];
    float3 ep0, ep1;
    fitBlock(blk, px, ep0, ep1);
    uint3 first = orderBC1(pack565(ep1), pack565(ep0), px);
    if (first.z == 0xffffffffu) return first.xy;
    uint bits = first.y;

    float aa = 0, ab = 0, bb = 0;
    float3 ax = 0.0, bx = 0.0;
    [unroll] for (uint i = 0; i < 16; i++) {
        float w = kBC1Weight[(bits >> (2 * i)) & 3u];
        aa += (1 - w) * (1 - w); ab += (1 - w) * w; bb += w * w;
        ax += (1 - w) * float3(px[i]); bx += w * float3(px[i]);
    }
    float det = aa * bb - ab * ab;
    if (det < 1e-3) return first.xy;
    uint3 refit = orderBC1(pack565((ax * bb - bx * ab) / det), pack565((bx * aa - ax * ab) / det), px);
    return refit.z < first.z ? refit.xy : first.xy;
}
""";

    public const string Kernels = """
Texture2D<float4> refTex : register(t1);
StructuredBuffer<uint> candList : register(t2);
RWStructuredBuffer<uint> dirtyOut : register(u1);

groupshared uint gDiff;

// One group per candidate tile: flags the tile when any RGB value differs from the reference texture
// (alpha is not meaningful in a capture and is ignored, as in the CPU path).
[numthreads(8, 8, 1)]
void tileDiffPix(uint3 gid : SV_GroupID, uint3 tid : SV_GroupThreadID) {
    uint tile = candList[gid.x];
    uint tilePx = tileBlocks * 4;
    uint x0 = (tile % tilesX) * tilePx;
    uint y0 = (tile / tilesX) * tilePx;
    uint li = tid.y * 8 + tid.x;
    if (li == 0) gDiff = 0;
    GroupMemoryBarrierWithGroupSync();
    uint step = tilePx / 8;
    uint diff = 0;
    for (uint j = 0; j < step; j++) {
        for (uint i = 0; i < step; i++) {
            uint x = x0 + tid.x + 8 * i;
            uint y = y0 + tid.y + 8 * j;
            if (x < width && y < height) {
                float3 a = src.Load(int3(x, y, 0)).rgb;
                float3 b = refTex.Load(int3(x, y, 0)).rgb;
                if (any(a != b)) diff = 1;
            }
        }
    }
    if (diff != 0) InterlockedOr(gDiff, 1);
    GroupMemoryBarrierWithGroupSync();
    if (li == 0) dirtyOut[tile] = gDiff;
}

struct TileEntry {
    uint tile;
    uint outBase;   // in 8-byte units
    uint runWidth;  // in blocks
    uint mode;      // 0/1 BC7 (changed tile / settling tile), 2 BC1
};

StructuredBuffer<TileEntry> table : register(t3);
RWStructuredBuffer<uint2> outUnits : register(u0);

// Grid (tileBlocks, tileBlocks, entries): one thread per block. Writes blocks in run order, row-major per run.
// Mode 1 (settle) encodes the tile's pixels from the current frame: a settling tile has not changed for
// settleDelay, so these are the same pixels the Mac sends from its BC7 reference.
[numthreads(8, 8, 1)]
void tileGather(uint3 id : SV_DispatchThreadID) {
    if (id.z >= candidates || id.x >= tileBlocks || id.y >= tileBlocks) return;
    TileEntry e = table[id.z];
    uint2 blk = uint2((e.tile % tilesX) * tileBlocks + id.x, (e.tile / tilesX) * tileBlocks + id.y);
    if (blk.x >= blocksX || blk.y >= blocksY) return;
    uint i = id.y * e.runWidth + id.x;
    if (e.mode == 2u) {
        outUnits[e.outBase + i] = encodeBC1(blk);
        return;
    }
    uint4 b = encodeBlock(blk);
    outUnits[e.outBase + 2 * i] = b.xy;
    outUnits[e.outBase + 2 * i + 1] = b.zw;
}
""";

    public const string Source = Header + "\n" + Bc7EncodeHlsl.Helpers + "\n" + Bc1 + "\n" + Kernels;
}
