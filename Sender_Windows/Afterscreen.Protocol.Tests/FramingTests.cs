using Afterscreen.Protocol;

namespace Afterscreen.Protocol.Tests;

public class FramingTests
{
    [Fact]
    public void EncodeDecodeRoundTrip()
    {
        var payload = JsonWire.Encode(new Hello
        {
            ProtocolVersion = 11,
            Name = "a",
            Model = "b",
            OsVersion = "c",
        });
        var msg = new Message(MessageType.Hello, 0, payload);
        var frame = Framing.Encode(msg);
        var back = Framing.Decode(frame);
        Assert.Equal(MessageType.Hello, back.Type);
        Assert.Equal(payload, back.Payload);
    }

    [Fact]
    public void TileFrame_RefinementFlag_RoundTrips()
    {
        var msg = new Message(MessageType.TileFrame, TileFlags.Refinement, new byte[] { 9, 8, 7 });
        var back = Framing.Decode(Framing.Encode(msg));
        Assert.Equal(MessageType.TileFrame, back.Type);
        Assert.Equal(TileFlags.Refinement, back.Flags);
        Assert.Equal(new byte[] { 9, 8, 7 }, back.Payload);
    }

    [Fact]
    public void FrameReaderReadsStream()
    {
        var a = Framing.Encode(new Message(MessageType.Ping, payload: new byte[] { 1, 2, 3 }));
        var b = Framing.Encode(new Message(MessageType.Pong, payload: new byte[] { 4 }));
        using var ms = new MemoryStream();
        ms.Write(a);
        ms.Write(b);
        ms.Position = 0;
        var reader = new FrameReader(ms);
        var m1 = reader.Next();
        var m2 = reader.Next();
        var m3 = reader.Next();
        Assert.NotNull(m1);
        Assert.NotNull(m2);
        Assert.Null(m3);
        Assert.Equal(MessageType.Ping, m1!.Value.Type);
        Assert.Equal(new byte[] { 1, 2, 3 }, m1.Value.Payload);
        Assert.Equal(MessageType.Pong, m2!.Value.Type);
    }
}
