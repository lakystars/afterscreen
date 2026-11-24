using Afterscreen.Protocol;

namespace Afterscreen.Protocol.Tests;

public class TileFrameTests
{
    [Fact]
    public void EmptyFrameIs16ByteAlignedHeaderOnly()
    {
        var g = new TileGeometry(2880, 1620);
        var payload = TileFrameWire.Empty(7, g);
        Assert.True(payload.Length % 16 == 0);
        var r = new ByteReader(payload);
        Assert.Equal(7u, r.U32());
        Assert.Equal(2880, r.U16());
        Assert.Equal(1620, r.U16());
        Assert.Equal(16, r.U8());
        Assert.Equal(0, r.U8());
        Assert.Equal(0, r.U16());
    }

    [Fact]
    public void FromMarksBuildsHorizontalRuns()
    {
        var g = new TileGeometry(192, 64); // 3×1 tiles
        byte[] marks = [1, 0, 1];
        var runs = TileRun.FromMarks(marks, g);
        Assert.Equal(2, runs.Count);
        Assert.Equal(new TileRun(0, 0, 1), runs[0]);
        Assert.Equal(new TileRun(0, 2, 1), runs[1]);
    }

    [Fact]
    public void VideoPresentMarksFullScreenVideoRuns()
    {
        var g = new TileGeometry(128, 128); // 2×2 tiles
        var payload = TileFrameWire.VideoPresent(3, g);
        var r = new ByteReader(payload);
        Assert.Equal(3u, r.U32());
        Assert.Equal(128, r.U16());
        Assert.Equal(128, r.U16());
        Assert.Equal(16, r.U8());
        Assert.Equal(0, r.U8()); // no chunks
        Assert.Equal(2, r.U16()); // two rows
        Assert.Equal(0, r.U16()); // row 0
        Assert.Equal(0, r.U16());
        Assert.Equal(2, r.U16());
        Assert.Equal((byte)TileFormat.Video, r.U8());
    }

    [Fact]
    public void VideoMaskOnlyMarkedTiles()
    {
        var g = new TileGeometry(128, 64); // 2×1 tiles
        byte[] marks = [0, 1];
        var payload = TileFrameWire.VideoMask(9, g, marks);
        var r = new ByteReader(payload);
        Assert.Equal(9u, r.U32());
        Assert.Equal(128, r.U16());
        Assert.Equal(64, r.U16());
        Assert.Equal(16, r.U8());
        Assert.Equal(0, r.U8());
        Assert.Equal(1, r.U16()); // one run
        Assert.Equal(0, r.U16()); // row
        Assert.Equal(1, r.U16()); // first tile
        Assert.Equal(1, r.U16()); // count
        Assert.Equal((byte)TileFormat.Video, r.U8());
    }
}
