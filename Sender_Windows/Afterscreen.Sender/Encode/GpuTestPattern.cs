using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Afterscreen.Sender.Capture;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using MapFlags = Vortice.Direct3D11.MapFlags;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// The Mac Sender's <c>TestPattern</c> on the GPU: moving test frames for the quality test, drawn straight into a
/// <see cref="GpuFrame"/> with a pixel shader (no CPU picture, so 5K stages cost nothing on the CPU).
/// <list type="bullet">
/// <item><b>Full</b>: every pixel changes every frame (aurora backdrop with grain, a moving card) - the worst case for
/// the tile path and the video layer alike.</item>
/// <item><b>Typical</b>: a still desktop with a moving video window and scrolling text, the way a screen is used.</item>
/// </list>
/// Caption text (Mac <c>QualityTest.caption</c>) is baked once per stage into a small texture and overlaid top-left.
/// </summary>
public sealed class GpuTestPattern : IDisposable
{
    private const string Hlsl = @"
cbuffer P : register(b0) {
    float2 size;
    float frame;
    float mode;
    float2 captionSize;
    float2 captionOrigin;
};

Texture2D captionTex : register(t0);

float4 vs_pos(uint id : SV_VertexID, out float2 uv : TEXCOORD0) : SV_Position
{
    uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float hash(float2 p) { p = frac(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return frac(p.x * p.y); }

float3 aurora(float2 uv, float t)
{
    float3 phase = float3(0.0, 0.33, 0.67);
    float3 c = 0.5 + 0.5 * cos(6.2831 * (uv.xyx * float3(0.8, 1.1, 0.6) + t * float3(0.20, 0.31, 0.17) + phase));
    c *= 0.55 + 0.45 * sin(uv.y * 9.0 + t * 1.3 + sin(uv.x * 5.0 - t));
    return c;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    float t = frame / 60.0;
    float2 px = pos.xy;
    float3 c;
    if (mode < 0.5)
    {
        c = aurora(uv, t) + (hash(px + frame) - 0.5) * 0.10;
        float2 centre = float2(0.5 + 0.3 * sin(t * 0.9), 0.5 + 0.25 * cos(t * 1.3));
        float2 d = abs(uv - centre) - float2(0.14, 0.09);
        if (max(d.x, d.y) < 0) c = lerp(c, float3(0.96, 0.97, 1.0), 0.85);
    }
    else
    {
        c = float3(0.13, 0.14, 0.17) + 0.02 * hash(floor(px / 64.0));
        float2 v0 = float2(0.04, 0.10), v1 = float2(0.52, 0.62);
        if (uv.x > v0.x && uv.x < v1.x && uv.y > v0.y && uv.y < v1.y)
            c = aurora((uv - v0) * 2.2, t) + (hash(px + frame) - 0.5) * 0.06;
        if (uv.x > 0.56 && uv.x < 0.96 && uv.y > 0.08 && uv.y < 0.92)
        {
            float y = px.y + frame * 3.0;
            float row = step(0.35, frac(y / 22.0));
            float word = step(0.25, hash(float2(floor(y / 22.0), floor(px.x / 40.0))));
            c = lerp(float3(0.97, 0.97, 0.98), float3(0.12, 0.12, 0.14), row * word * 0.9);
        }
    }
    // Mac caption overlay: premultiplied-ish alpha from GDI (white text on transparent).
    if (captionSize.x > 0.5)
    {
        float2 cp = px - captionOrigin;
        if (cp.x >= 0 && cp.y >= 0 && cp.x < captionSize.x && cp.y < captionSize.y)
        {
            float4 cap = captionTex.Load(int3(cp, 0));
            c = lerp(c, cap.rgb, cap.a);
        }
    }
    return float4(saturate(c.bgr), 1);
}
";

    private readonly D3dEncodeDevice _device;
    private readonly ID3D11VertexShader _vs;
    private readonly ID3D11PixelShader _ps;
    private readonly ID3D11Buffer _cb;
    private ID3D11Texture2D? _captionTex;
    private ID3D11ShaderResourceView? _captionSrv;
    private int _captionW, _captionH;
    private string? _captionText;

    public GpuTestPattern(D3dEncodeDevice device)
    {
        _device = device;
        var d = device.Device;
        var vs = Compiler.Compile(Hlsl, "vs_pos", "GpuTestPattern.hlsl", "vs_5_0");
        var ps = Compiler.Compile(Hlsl, "main", "GpuTestPattern.hlsl", "ps_5_0");
        _vs = d.CreateVertexShader(vs.Span);
        _ps = d.CreatePixelShader(ps.Span);
        _cb = d.CreateBuffer(new BufferDescription
        {
            ByteWidth = 32, // size(8)+frame(4)+mode(4)+captionSize(8)+captionOrigin(8)
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ConstantBuffer,
            CPUAccessFlags = CpuAccessFlags.Write,
        });
    }

    /// <summary>Mac caption texture for this stage; rebuilt when the text changes. Null/empty clears it.</summary>
    public void SetCaption(string? text, int streamHeight)
    {
        text ??= "";
        if (text.Length == 0)
        {
            ClearCaption();
            return;
        }
        if (text == _captionText && _captionSrv is not null) return;
        ClearCaption();
        _captionText = text;
        var fontPx = Math.Max(14, (int)(0.022 * streamHeight));
        using var bmp = BakeCaption(text, fontPx);
        _captionW = bmp.Width;
        _captionH = bmp.Height;
        UploadCaption(bmp);
    }

    private void ClearCaption()
    {
        _captionSrv?.Dispose();
        _captionTex?.Dispose();
        _captionSrv = null;
        _captionTex = null;
        _captionW = _captionH = 0;
        _captionText = null;
    }

    private static Bitmap BakeCaption(string text, int fontPx)
    {
        using var measureFont = new Font("Segoe UI", fontPx, FontStyle.Regular, GraphicsUnit.Pixel);
        var pad = Math.Max(4, fontPx / 4);
        SizeF size;
        using (var tmp = new Bitmap(8, 8))
        using (var g = Graphics.FromImage(tmp))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            size = g.MeasureString(text, measureFont);
        }
        var w = Math.Max(4, (int)Math.Ceiling(size.Width) + pad * 2);
        var h = Math.Max(4, (int)Math.Ceiling(size.Height) + pad * 2);
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var font = new Font("Segoe UI", fontPx, FontStyle.Regular, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(Color.FromArgb(235, 255, 255, 255));
            g.DrawString(text, font, brush, pad, pad);
        }
        return bmp;
    }

    private void UploadCaption(Bitmap bmp)
    {
        var d = _device.Device;
        _captionTex = d.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)bmp.Width,
            Height = (uint)bmp.Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource,
        });
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            // GDI is BGRA; shader Load is RGBA — swap B/R when uploading.
            var row = new byte[bmp.Width * 4];
            var all = new byte[bmp.Width * bmp.Height * 4];
            for (var y = 0; y < bmp.Height; y++)
            {
                Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                for (var x = 0; x < bmp.Width; x++)
                {
                    var i = x * 4;
                    var o = (y * bmp.Width + x) * 4;
                    all[o] = row[i + 2];
                    all[o + 1] = row[i + 1];
                    all[o + 2] = row[i];
                    all[o + 3] = row[i + 3];
                }
            }
            var handle = GCHandle.Alloc(all, GCHandleType.Pinned);
            try
            {
                var box = new Vortice.Mathematics.Box(0, 0, 0, bmp.Width, bmp.Height, 1);
                _device.Context.UpdateSubresource(_captionTex, 0, box, handle.AddrOfPinnedObject(), (uint)(bmp.Width * 4), 0);
            }
            finally { handle.Free(); }
        }
        finally
        {
            bmp.UnlockBits(data);
        }
        _captionSrv = d.CreateShaderResourceView(_captionTex);
    }

    /// <summary>Draws frame <paramref name="index"/> of the pattern into <paramref name="target"/> (must be a render-target frame).</summary>
    public void Render(GpuFrame target, int index, bool typical)
    {
        var ctx = _device.Context;
        var m = ctx.Map(_cb, MapMode.WriteDiscard, MapFlags.None);
        var origin = Math.Max(8f, target.Height * 0.042f);
        var floats = new[]
        {
            (float)target.Width, (float)target.Height, (float)index, typical ? 1f : 0f,
            (float)_captionW, (float)_captionH, origin, origin,
        };
        Marshal.Copy(floats, 0, m.DataPointer, floats.Length);
        ctx.Unmap(_cb);

        ctx.OMSetRenderTargets(target.Rtv!);
        ctx.RSSetViewport(0, 0, target.Width, target.Height);
        ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        ctx.IASetInputLayout(null);
        ctx.VSSetShader(_vs);
        ctx.PSSetShader(_ps);
        ctx.PSSetConstantBuffer(0, _cb);
        if (_captionSrv is not null)
            ctx.PSSetShaderResource(0, _captionSrv);
        ctx.Draw(3, 0);
        if (_captionSrv is not null)
            ctx.PSSetShaderResource(0, (ID3D11ShaderResourceView?)null!);
        ctx.OMSetRenderTargets((ID3D11RenderTargetView?)null!);
        ctx.PSSetShader(null);
        ctx.VSSetShader(null);
    }

    public void Dispose()
    {
        ClearCaption();
        _cb.Dispose();
        _ps.Dispose();
        _vs.Dispose();
    }
}
