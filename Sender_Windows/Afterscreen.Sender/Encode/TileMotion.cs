namespace Afterscreen.Sender.Encode;

/// <summary>Mac <c>TileEncoder.Motion</c>.</summary>
public enum TileMotion
{
    /// <summary>Dirty tiles as BC1; settle → BC7.</summary>
    Bc1,
    /// <summary>Dirty tiles straight as BC7 (small, still updates such as typing).</summary>
    Bc7,
    /// <summary>Dirty/lossy tiles as video runs (hybrid).</summary>
    Video,
}
