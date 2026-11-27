using Afterscreen.Protocol;

namespace Afterscreen.Protocol.Tests;

public class PairingTests
{
    private static Pairing.Transcript Transcript(Pairing.KeyPair s, Pairing.KeyPair r, byte[] sn, byte[] rn) =>
        new("mac", "imac", sn, rn, s.PublicKey, r.PublicKey);

    [Fact]
    public void ShownCodePairsBothSidesOnOneKey()
    {
        using var s = Pairing.NewKey();
        using var r = Pairing.NewKey();
        var sn = Pairing.Nonce();
        var rn = Pairing.Nonce();
        var t = Transcript(s, r, sn, rn);
        var senderSession = Pairing.SessionKey(s, r.PublicKey, t);
        var receiverSession = Pairing.SessionKey(r, s.PublicKey, t);
        var code = Pairing.Code();
        Assert.Equal(6, code.Length);
        Assert.True(Pairing.Matches(
            Pairing.Confirm(senderSession, code, t),
            Pairing.Confirm(receiverSession, code, t)));
        var wrong = code == "000000" ? "000001" : code;
        Assert.False(Pairing.Matches(
            Pairing.Confirm(senderSession, "000000", t),
            Pairing.Confirm(receiverSession, wrong, t)));
        Assert.Equal(
            Pairing.PairingKey(senderSession, code, t),
            Pairing.PairingKey(receiverSession, code, t));
        Assert.Equal(
            Pairing.PairedProof(senderSession, t),
            Pairing.PairedProof(receiverSession, t));
    }

    [Fact]
    public void ProofsAreBoundToRoleAndNonces()
    {
        var key = Pairing.Nonce().Concat(Pairing.Nonce()).ToArray();
        var t = new Pairing.Transcript("mac", "imac", Pairing.Nonce(), Pairing.Nonce());
        var sender = Pairing.Proof(key, Pairing.Role.Sender, t);
        Assert.True(Pairing.Matches(sender, Pairing.Proof(key, Pairing.Role.Sender, t)));
        Assert.False(Pairing.Matches(sender, Pairing.Proof(key, Pairing.Role.Receiver, t)));
        var replay = new Pairing.Transcript(t.SenderID, t.ReceiverID, t.SenderNonce, Pairing.Nonce());
        Assert.False(Pairing.Matches(sender, Pairing.Proof(key, Pairing.Role.Sender, replay)));
        Assert.False(Pairing.Matches(sender, Pairing.Proof(Pairing.Nonce().Concat(Pairing.Nonce()).ToArray(), Pairing.Role.Sender, t)));
    }

    [Fact]
    public void TranscriptPartsCannotShiftIntoEachOther()
    {
        var a = new Pairing.Transcript("ab", "c", Array.Empty<byte>(), Array.Empty<byte>());
        var b = new Pairing.Transcript("a", "bc", Array.Empty<byte>(), Array.Empty<byte>());
        Assert.NotEqual(a.Bytes, b.Bytes);
    }

    [Fact]
    public void HelloWelcomeRoundTripJson()
    {
        var hello = new Hello
        {
            ProtocolVersion = AfterscreenProtocol.Version,
            Name = "WinPC",
            Model = "IrisXe",
            OsVersion = "10.0",
            SenderID = "sender-1",
            Nonce = Pairing.Nonce(),
            Paired = false,
            ReadsOptions = true,
        };
        var bytes = JsonWire.Encode(hello);
        var back = JsonWire.Decode<Hello>(bytes);
        Assert.Equal(hello.ProtocolVersion, back.ProtocolVersion);
        Assert.Equal(hello.SenderID, back.SenderID);
        Assert.Equal(hello.Nonce, back.Nonce);

        var welcomeJson = """
            {"protocolVersion":11,"name":"iMac","modelID":"iMac21,1","marketingName":"iMac",
             "osVersion":"15.0","gpuNames":["Apple M1"],"panelPixels":{"width":5120,"height":2880},
             "panelPoints":{"width":2560,"height":1440},"hevcDecode":true,"h264Decode":true,"bc7":true,
             "hevcMain10Decode":true,"audioPlayback":true,"channelToken":42,"receiverID":"recv-1",
             "auth":{"mode":"pair","nonce":"AAAAAAAAAAAAAAAAAAAAAA==","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}
            """;
        var welcome = JsonWire.Decode<Welcome>(System.Text.Encoding.UTF8.GetBytes(welcomeJson));
        Assert.Equal(11, welcome.ProtocolVersion);
        Assert.Equal(AuthMode.pair, welcome.Auth!.Mode);
        Assert.Equal("recv-1", welcome.ReceiverID);
    }
}
