using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Afterscreen.Sender.Capture;

/// <summary>
/// The current screen picture kept in GPU memory (the Windows counterpart of the <c>MTLTexture</c> the Mac Sender
/// wraps around the ScreenCaptureKit pixel buffer). One persistent BGRA texture, updated in place for the regions
/// that changed; the tile encoder reads it directly, so no full frame is read back or uploaded per frame.
/// </summary>
public sealed class GpuFrame : IDisposable
{
    public ID3D11Device Device { get; }
    public ID3D11Texture2D Texture { get; }
    public ID3D11ShaderResourceView Srv { get; }
    /// <summary>Only when created as a render target (the quality test draws its pattern into it).</summary>
    public ID3D11RenderTargetView? Rtv { get; }
    public int Width { get; }
    public int Height { get; }

    public GpuFrame(ID3D11Device device, int width, int height, bool renderTarget = false)
    {
        Device = device;
        Width = width;
        Height = height;
        Texture = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = renderTarget ? BindFlags.ShaderResource | BindFlags.RenderTarget : BindFlags.ShaderResource,
        });
        Srv = device.CreateShaderResourceView(Texture);
        if (renderTarget) Rtv = device.CreateRenderTargetView(Texture);
    }

    /// <summary>Whole picture from system memory (tests and tools).</summary>
    public void Upload(ID3D11DeviceContext context, byte[] bgra)
    {
        var handle = GCHandle.Alloc(bgra, GCHandleType.Pinned);
        try
        {
            var box = new Vortice.Mathematics.Box(0, 0, 0, Width, Height, 1);
            context.UpdateSubresource(Texture, 0, box, handle.AddrOfPinnedObject(), (uint)(Width * 4), 0);
        }
        finally
        {
            handle.Free();
        }
    }

    public void Dispose()
    {
        Rtv?.Dispose();
        Srv.Dispose();
        Texture.Dispose();
    }
}
