namespace Afterscreen.Sender.Encode;

public enum TileCompression { None, All, FirstChunk }

/// <summary>
/// Port of the Mac <c>CompressionPolicy</c>: per-frame LZ4 decision. Frames that fit the link with headroom go
/// stored (a copy costs less than LZ4 on both ends); bigger frames, or any frame while the link is congested,
/// compress while the data is compressible; incompressible content is rechecked with one chunk every
/// <see cref="ProbeInterval"/> frames.
/// </summary>
public sealed class CompressionPolicy
{
    public const double MinRatio = 1.25;
    public const int ProbeInterval = 30;
    /// <summary>Frames treated as congested after a full send queue.</summary>
    public const int CongestionFrames = 120;
    private const double Headroom = 1.3;

    private readonly double _capacityBits;
    private readonly double _fps;
    private int _congested;
    private bool _compressible = true;
    private int _untilProbe;

    public CompressionPolicy(double? capacityGbps, double fps)
    {
        _capacityBits = (capacityGbps ?? 0) * 1e9;
        _fps = fps;
    }

    public TileCompression Next(int rawBytes, bool queueWasFull)
    {
        if (queueWasFull) _congested = CongestionFrames;
        var tooBig = rawBytes * 8.0 * _fps * Headroom > _capacityBits;
        if (!tooBig && _congested <= 0) return TileCompression.None;
        _congested = Math.Max(0, _congested - 1);
        if (_compressible) return TileCompression.All;
        _untilProbe--;
        return _untilProbe <= 0 ? TileCompression.FirstChunk : TileCompression.None;
    }

    /// <summary>LZ4 input and output bytes of the last frame.</summary>
    public void Record(int rawBytes, int wireBytes)
    {
        if (rawBytes <= 0) return;
        _compressible = rawBytes >= Math.Max(1, wireBytes) * MinRatio;
        if (!_compressible) _untilProbe = ProbeInterval;
    }
}
