using System.Runtime.InteropServices;
using Afterscreen.Sender.Capture;
using Vortice.D3DCompiler;
using Vortice.Direct3D11;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// Scales the GPU picture to the video size and converts it to NV12 / P010 (BT.709 video range) on the GPU.
/// Replaces the CPU nearest-neighbour scale + BGRA->YUV loops of the legacy path: the video layer's input is
/// produced by one compute dispatch and read back as the finished YUV bytes (1.5 bytes/pixel, 3 for P010)
/// instead of reading back and converting 4 bytes/pixel on the CPU. Each output pixel averages 4 source taps
/// (a small box filter), so a 1.5x downscale keeps text edges instead of dropping rows and columns.
/// </summary>
public sealed class GpuVideoConverter : IDisposable
{
    private const string Hlsl = @"
cbuffer P : register(b0) { uint dstW; uint dstH; uint tenBit; uint pad; };
Texture2D<float4> src : register(t0);
SamplerState smp : register(s0);
RWStructuredBuffer<uint> dst : register(u0);

float3 Px(uint x, uint y)
{
    float2 uv = (float2(x, y) + 0.5) / float2(dstW, dstH);
    float2 d = 0.25 / float2(dstW, dstH);
    return 0.25 * (src.SampleLevel(smp, uv + float2(-d.x, -d.y), 0).rgb + src.SampleLevel(smp, uv + float2(d.x, -d.y), 0).rgb
                 + src.SampleLevel(smp, uv + float2(-d.x, d.y), 0).rgb + src.SampleLevel(smp, uv + float2(d.x, d.y), 0).rgb);
}

float Luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// 8-bit: thread = 4x2 pixels; 10-bit: thread = 2x2 pixels.
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint n = tenBit != 0 ? 2 : 4;
    uint px = id.x * n;
    uint py = id.y * 2;
    if (px >= dstW || py >= dstH) return;

    float3 c[2][4];
    [unroll] for (uint r = 0; r < 2; r++)
        [unroll] for (uint i = 0; i < 4; i++)
            c[r][i] = (i < n) ? Px(px + i, py + r) : float3(0, 0, 0);

    uint ySize = dstW * dstH;
    if (tenBit != 0)
    {
        [unroll] for (uint r = 0; r < 2; r++)
        {
            uint a = (uint)clamp(round(64 + 876 * Luma(c[r][0])), 64, 940) << 6;
            uint b = (uint)clamp(round(64 + 876 * Luma(c[r][1])), 64, 940) << 6;
            dst[((py + r) * dstW + px) / 2] = a | (b << 16);
        }
        float3 m = 0.25 * (c[0][0] + c[0][1] + c[1][0] + c[1][1]);
        float y = Luma(m);
        uint cb = (uint)clamp(round(512 + 896 * ((m.b - y) / 1.8556)), 64, 960) << 6;
        uint cr = (uint)clamp(round(512 + 896 * ((m.r - y) / 1.5748)), 64, 960) << 6;
        dst[ySize / 2 + ((py / 2) * dstW + px) / 2] = cb | (cr << 16);
    }
    else
    {
        [unroll] for (uint r = 0; r < 2; r++)
        {
            uint w = 0;
            [unroll] for (uint i = 0; i < 4; i++)
                w |= (uint)clamp(round(16 + 219 * Luma(c[r][i])), 16, 235) << (8 * i);
            dst[((py + r) * dstW + px) / 4] = w;
        }
        uint uv = 0;
        [unroll] for (uint j = 0; j < 2; j++)
        {
            float3 m = 0.25 * (c[0][2 * j] + c[0][2 * j + 1] + c[1][2 * j] + c[1][2 * j + 1]);
            float y = Luma(m);
            uint cb = (uint)clamp(round(128 + 224 * ((m.b - y) / 1.8556)), 16, 240);
            uint cr = (uint)clamp(round(128 + 224 * ((m.r - y) / 1.5748)), 16, 240);
            uv |= (cb << (16 * j)) | (cr << (16 * j + 8));
        }
        dst[(ySize + (py / 2) * dstW + px) / 4] = uv;
    }
}
";

    private readonly D3dEncodeDevice _device;
    private readonly int _w, _h;
    private readonly bool _tenBit;
    private readonly ID3D11ComputeShader _cs;
    private readonly ID3D11Buffer _cb;
    private readonly ID3D11SamplerState _sampler;
    private readonly ID3D11Buffer _outBuf;
    private readonly ID3D11UnorderedAccessView _outUav;
    private readonly ID3D11Buffer _staging;
    private readonly int _outBytes;

    public int OutputBytes => _outBytes;

    /// <summary>Output size must be a multiple of 4 horizontally and 2 vertically.</summary>
    public static bool Supports(int w, int h) => w % 4 == 0 && h % 2 == 0;

    public GpuVideoConverter(D3dEncodeDevice device, int dstWidth, int dstHeight, bool tenBit)
    {
        _device = device;
        _w = dstWidth;
        _h = dstHeight;
        _tenBit = tenBit;
        _outBytes = tenBit ? dstWidth * dstHeight * 3 : dstWidth * dstHeight * 3 / 2;
        var d = device.Device;
        var code = Compiler.Compile(Hlsl, "main", "GpuVideoConverter.hlsl", "cs_5_0", ShaderFlags.OptimizationLevel3);
        _cs = d.CreateComputeShader(code.Span);
        _cb = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = 16,
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ConstantBuffer,
            CPUAccessFlags = CpuAccessFlags.Write,
        });
        _sampler = d.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipLinear,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            ComparisonFunc = ComparisonFunction.Never,
            MaxLOD = float.MaxValue,
        });
        _outBuf = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)_outBytes,
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.UnorderedAccess,
            StructureByteStride = 4,
            MiscFlags = ResourceOptionFlags.BufferStructured,
        });
        _outUav = d.CreateUnorderedAccessView(_outBuf);
        _staging = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = (uint)_outBytes,
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
    }

    /// <summary>Converts the whole picture into <paramref name="yuv"/> (at least <see cref="OutputBytes"/> long).</summary>
    public unsafe void Convert(GpuFrame frame, byte[] yuv)
    {
        if (yuv.Length < _outBytes) throw new ArgumentException("buffer too small", nameof(yuv));
        fixed (byte* p = yuv)
            Convert(frame, (IntPtr)p);
    }

    /// <summary>Same into native memory of at least <see cref="OutputBytes"/>.</summary>
    public void Convert(GpuFrame frame, IntPtr yuv)
    {
        lock (_device.ContextLock)
            ConvertLocked(frame, yuv);
    }

    private unsafe void ConvertLocked(GpuFrame frame, IntPtr yuv)
    {
        var ctx = _device.Context;
        var mapped = ctx.Map(_cb, MapMode.WriteDiscard, MapFlags.None);
        Marshal.WriteInt32(mapped.DataPointer, 0, _w);
        Marshal.WriteInt32(mapped.DataPointer, 4, _h);
        Marshal.WriteInt32(mapped.DataPointer, 8, _tenBit ? 1 : 0);
        ctx.Unmap(_cb);

        ctx.CSSetShader(_cs);
        ctx.CSSetConstantBuffer(0, _cb);
        ctx.CSSetSampler(0, _sampler);
        ctx.CSSetShaderResource(0, frame.Srv);
        ctx.CSSetUnorderedAccessView(0, _outUav);
        var n = _tenBit ? 2 : 4;
        ctx.Dispatch((uint)((_w / n + 7) / 8), (uint)((_h / 2 + 7) / 8), 1);
        ctx.CSSetUnorderedAccessView(0, (ID3D11UnorderedAccessView?)null!);
        ctx.CSSetShaderResource(0, (ID3D11ShaderResourceView?)null!);
        ctx.CSSetConstantBuffer(0, (ID3D11Buffer?)null!);
        ctx.CSSetShader(null);

        ctx.CopyResource(_staging, _outBuf);
        ctx.Flush();
        var m = ctx.Map(_staging, 0, MapMode.Read, MapFlags.None);
        try
        {
            Buffer.MemoryCopy((void*)m.DataPointer, (void*)yuv, _outBytes, _outBytes);
        }
        finally
        {
            ctx.Unmap(_staging, 0);
        }
    }

    public void Dispose()
    {
        _staging.Dispose();
        _outUav.Dispose();
        _outBuf.Dispose();
        _sampler.Dispose();
        _cb.Dispose();
        _cs.Dispose();
    }
}
