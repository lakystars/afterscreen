using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// D3D11 device bound to a DXGI adapter. Shared by MF HW encode (via DXGI manager) and future HLSL BC7.
/// Vendor-agnostic: pass any GpuAdapterInfo (Iris / NVIDIA / AMD).
/// </summary>
public sealed class D3dEncodeDevice : IDisposable
{
    public GpuAdapterInfo Adapter { get; }
    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }

    /// <summary>
    /// Held for each multi-call sequence on <see cref="Context"/> (capture's region copies, a whole tile encode, a
    /// video conversion): multithread protection only orders single calls, and a capture copy landing between a
    /// tile diff and its reference update would leave the reference ahead of what was sent.
    /// </summary>
    public object ContextLock { get; } = new();

    private D3dEncodeDevice(GpuAdapterInfo adapter, ID3D11Device device, ID3D11DeviceContext context)
    {
        Adapter = adapter;
        Device = device;
        Context = context;
    }

    public static D3dEncodeDevice? TryCreate(GpuAdapterInfo? preferred = null)
    {
        preferred ??= GpuAdapters.Prefer();
        if (preferred is null || !preferred.IsHardware)
            return null;

        try
        {
            using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
            for (uint i = 0; factory.EnumAdapters1(i, out var adapter).Success; i++)
            {
                using (adapter)
                {
                    var d = adapter.Description1;
                    var luid = ((long)d.Luid.HighPart << 32) | (uint)d.Luid.LowPart;
                    if (luid != preferred.AdapterLuid)
                        continue;

                    // VideoSupport helps MF/QSV; fall back if the driver rejects the flag.
                    ID3D11Device? device = null;
                    ID3D11DeviceContext? context = null;
                    var hr = D3D11.D3D11CreateDevice(
                        adapter, DriverType.Unknown,
                        DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
                        new[] { FeatureLevel.Level_11_0 },
                        out device, out _, out context);
                    if (hr.Failure)
                    {
                        hr = D3D11.D3D11CreateDevice(
                            adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
                            new[] { FeatureLevel.Level_11_0 },
                            out device, out _, out context);
                    }
                    if (hr.Failure || device is null || context is null)
                        return null;

                    try
                    {
                        using var mt = device.QueryInterface<ID3D11Multithread>();
                        mt.SetMultithreadProtected(true);
                    }
                    catch { /* optional */ }

                    return new D3dEncodeDevice(preferred, device, context);
                }
            }
        }
        catch
        {
            return null;
        }
        return null;
    }

    public void Dispose()
    {
        Context.Dispose();
        Device.Dispose();
    }
}
