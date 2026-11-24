namespace Afterscreen.Sender.Encode;

public readonly struct TileDirtyProbe
{
    public int DirtyTiles { get; init; }
    public int TotalTiles { get; init; }
    public bool Keyframe { get; init; }
    /// <summary>Per-tile marks from the last Probe (0=clean, else dirty). Length = TotalTiles.</summary>
    public required byte[] Marks { get; init; }
    public double DirtyShare => TotalTiles <= 0 ? 0 : DirtyTiles / (double)TotalTiles;
}

/// <summary>
/// Wire-facing tile encoder. Session never binds to a GPU vendor.
/// Backends may be CPU, D3D11 compute (Iris/NVIDIA/AMD via DXGI adapter), etc.
/// </summary>
public interface ITileEncoder : IDisposable
{
    /// <summary>Log id, e.g. "cpu-bc7" or "d3d11-bc7:Intel(R) Iris(R) Xe".</summary>
    string BackendName { get; }

    /// <summary>Mac <c>TileEncoder.motion</c>.</summary>
    TileMotion Motion { get; set; }

    /// <summary>Per tile: true while the receiver shows it as lossy BC1 (cleared once sent as BC7).</summary>
    bool[] LossyBc1 { get; }

    /// <summary>
    /// Dirty estimate without encoding — used to pick video vs tiles.
    /// <paramref name="dirty"/>: capture-reported changed regions (frame pixels), merged across
    /// any frames dropped since the last processed one; null = unknown (compare all tiles).
    /// </summary>
    TileDirtyProbe Probe(byte[] bgra, int width, int height, IReadOnlyList<System.Drawing.Rectangle>? dirty = null);

    EncodedTileFrame? Encode(byte[] bgra, int width, int height, uint frameIndex);

    /// <summary>
    /// Encode only marked tiles (mark 1=BC7, 2=BC1, 3=video). Video runs carry no payload.
    /// Mac: motion=.video or .bc1; settle → BC7.
    /// </summary>
    EncodedTileFrame? EncodeMarks(byte[] bgra, int width, int height, uint frameIndex, byte[] marks);

    /// <summary>Advance the dirty reference without encoding (e.g. after a video-layer frame).</summary>
    void NotePresented(byte[] bgra);

    void Reset();
}
