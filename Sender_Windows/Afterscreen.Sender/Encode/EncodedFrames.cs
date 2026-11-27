namespace Afterscreen.Sender.Encode;

public sealed class EncodedTileFrame
{
    public required byte[] Payload { get; init; }
    public int DirtyTiles { get; init; }
    public int TotalTiles { get; init; }
    public bool Keyframe { get; init; }
}

public sealed class EncodedVideoFrame
{
    public required bool Keyframe { get; init; }
    public required byte[] Avcc { get; init; }
    public byte[][]? ParameterSets { get; init; }
}
