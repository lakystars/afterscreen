using System.Text;
using Afterscreen.Protocol;

namespace Afterscreen.Protocol.Tests;

public class HandoverTests
{
    private readonly byte[] _token = Pairing.Nonce();
    private readonly byte[] _key = Pairing.Nonce();
    private readonly byte[] _sender = Pairing.Nonce();
    private readonly byte[] _receiver = Pairing.Nonce();

    [Fact]
    public void BothSidesDeriveTheSameProofs()
    {
        var a = Handover.Secret(_key, _token);
        var b = Handover.Secret(_key, _token);
        Assert.Equal(
            Handover.Proof(a, Handover.Role.Sender, _sender, _receiver),
            Handover.Proof(b, Handover.Role.Sender, _sender, _receiver));
    }

    [Fact]
    public void ProofsBindRoleNoncesKeyAndToken()
    {
        var secret = Handover.Secret(_key, _token);
        var proof = Handover.Proof(secret, Handover.Role.Sender, _sender, _receiver);
        Assert.NotEqual(proof, Handover.Proof(secret, Handover.Role.Receiver, _sender, _receiver)); // no reflection
        Assert.NotEqual(proof, Handover.Proof(secret, Handover.Role.Sender, _sender, Pairing.Nonce())); // fresh challenge
        Assert.NotEqual(proof, Handover.Proof(Handover.Secret(Pairing.Nonce(), _token), Handover.Role.Sender, _sender, _receiver)); // another pairing
        Assert.NotEqual(proof, Handover.Proof(Handover.Secret(_key, Pairing.Nonce()), Handover.Role.Sender, _sender, _receiver)); // another session
        Assert.NotEqual(proof, Handover.Proof(Handover.Secret(null, _token), Handover.Role.Sender, _sender, _receiver)); // key matters
    }

    [Fact]
    public void WelcomeCarriesTheTokenOnlyWhenSet()
    {
        var welcome = new Welcome
        {
            ProtocolVersion = 1,
            Name = "iMac",
            ModelID = "iMac18,3",
            MarketingName = "iMac",
            OsVersion = "13.7",
            PanelPixels = new PixelSize(5120, 2880),
            PanelPoints = new PixelSize(2560, 1440),
            HevcDecode = true,
            H264Decode = true,
            Bc7 = true,
        };
        var json = Encoding.UTF8.GetString(JsonWire.Encode(welcome));
        Assert.DoesNotContain("handoverToken", json, StringComparison.Ordinal);
        welcome.HandoverToken = _token;
        var round = JsonWire.Decode<Welcome>(JsonWire.Encode(welcome));
        Assert.Equal(_token, round.HandoverToken);
    }

    [Fact]
    public void HandoverNonceRoundTrips()
    {
        var n = new HandoverNonce { Nonce = Pairing.Nonce() };
        var round = JsonWire.Decode<HandoverNonce>(JsonWire.Encode(n));
        Assert.Equal(n.Nonce, round.Nonce);
    }
}
