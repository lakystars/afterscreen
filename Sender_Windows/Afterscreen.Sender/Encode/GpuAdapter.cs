using Vortice.DXGI;

namespace Afterscreen.Sender.Encode;

/// <summary>DXGI adapter snapshot. Vendor-agnostic; Iris is just one preferred VendorId.</summary>
public sealed record GpuAdapterInfo(
    long AdapterLuid,
    string Description,
    uint VendorId,
    uint DeviceId,
    bool IsHardware)
{
    public const uint VendorIntel = 0x8086;
    public const uint VendorNvidia = 0x10DE;
    public const uint VendorAmd = 0x1002;

    public bool IsIntel => VendorId == VendorIntel;
    public bool IsNvidia => VendorId == VendorNvidia;
    public bool IsAmd => VendorId == VendorAmd;
}

public static class GpuAdapters
{
    /// <summary>Hardware adapters first (Intel → NVIDIA → AMD → other), then WARP.</summary>
    public static IReadOnlyList<GpuAdapterInfo> List()
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        var list = new List<GpuAdapterInfo>();
        for (uint i = 0; factory.EnumAdapters1(i, out var adapter).Success; i++)
        {
            using (adapter)
            {
                var d = adapter.Description1;
                list.Add(new GpuAdapterInfo(
                    ((long)d.Luid.HighPart << 32) | (uint)d.Luid.LowPart,
                    d.Description ?? $"Adapter{i}",
                    d.VendorId,
                    d.DeviceId,
                    (d.Flags & AdapterFlags.Software) == 0));
            }
        }
        return list
            .OrderByDescending(a => a.IsHardware)
            .ThenBy(a => a.IsIntel ? 0 : a.IsNvidia ? 1 : a.IsAmd ? 2 : 3)
            .ToList();
    }

    public static GpuAdapterInfo? Prefer(IEnumerable<GpuAdapterInfo>? adapters = null)
    {
        var list = adapters?.ToList() ?? List().ToList();
        return list.FirstOrDefault(a => a.IsHardware && a.IsIntel)
               ?? list.FirstOrDefault(a => a.IsHardware)
               ?? list.FirstOrDefault();
    }
}
