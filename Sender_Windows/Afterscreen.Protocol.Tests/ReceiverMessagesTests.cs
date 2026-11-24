using System.Text;
using Afterscreen.Protocol;
using Xunit;

namespace Afterscreen.Protocol.Tests;

public class ReceiverMessagesTests
{
    [Fact]
    public void ReceiverStatsDecodesTheMacShape()
    {
        const string json = """{"receivedFPS":59.5,"displayedFPS":60,"uploadMs":1.5,"decompressMs":0.25,"lateFrames":2,"cpuPercent":12,"memoryBytes":2548039680,"gpuPercent":17.5,"shown":true}""";
        var s = JsonWire.Decode<ReceiverStats>(Encoding.UTF8.GetBytes(json));
        Assert.Equal(59.5, s.ReceivedFPS);
        Assert.Equal(60, s.DisplayedFPS);
        Assert.Equal(2548039680UL, s.MemoryBytes);
        Assert.True(s.Shown);
        Assert.Null(s.AudioBufferMs);
    }

    [Fact]
    public void ReceiverOptionsDecodesAndAppliesAChange()
    {
        const string json = """{"editable":true,"hud":false,"presentation":"space","screens":[{"key":"A1","name":"Studio Display","pixels":{"width":5120,"height":2880}}],"matchPanelMode":true,"effect":"tiles","onDisconnect":"showDesktop","launchAtLogin":false}""";
        var o = JsonWire.Decode<ReceiverOptions>(Encoding.UTF8.GetBytes(json));
        Assert.True(o.Editable);
        Assert.Equal(ReceiverPresentation.space, o.Presentation);
        Assert.Equal("Studio Display", o.Screens[0].Name);
        Assert.Null(o.Screen);

        var next = o.Applying(new ReceiverOptionsChange { Hud = true, Screen = "A1", Effect = ReceiverEffect.none });
        Assert.True(next.Hud);
        Assert.Equal("A1", next.Screen);
        Assert.Equal(ReceiverEffect.none, next.Effect);
        Assert.False(o.Hud);                                    // the original is untouched
        Assert.Null(o.Applying(new ReceiverOptionsChange { Screen = "unknown" }).Screen);   // not a listed screen: ignored
    }

    [Fact]
    public void ReceiverOptionsChangeUsesTheMacFieldNamesAndSkipsNulls()
    {
        var bytes = JsonWire.Encode(new ReceiverOptionsChange { Presentation = ReceiverPresentation.cover, OnDisconnect = ReceiverOnDisconnect.sleepDisplay });
        Assert.Equal("""{"presentation":"cover","onDisconnect":"sleepDisplay"}""", Encoding.UTF8.GetString(bytes));
    }

    [Fact]
    public void PowerOffByeEncodesReasonAndPowerLikeMac()
    {
        Assert.Equal((byte)0x27, (byte)MessageType.PowerOff);
        var withPower = JsonWire.Encode(new Bye { Reason = "Disconnect", Power = ReceiverPower.sleep });
        Assert.Equal("""{"reason":"Disconnect","pause":false,"relink":false,"power":"sleep"}""", Encoding.UTF8.GetString(withPower));
        var keepOn = JsonWire.Encode(new Bye { Reason = "Disconnect", Power = null });
        Assert.Equal("""{"reason":"Disconnect","pause":false,"relink":false}""", Encoding.UTF8.GetString(keepOn));
    }
}
