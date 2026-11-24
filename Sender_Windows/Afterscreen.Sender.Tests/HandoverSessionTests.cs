using Afterscreen.Protocol;
using Afterscreen.Sender.Testing;
using Afterscreen.Transport;
using Xunit;

namespace Afterscreen.Sender.Tests;

public class HandoverSessionTests
{
    [Fact]
    public async Task FakeReceiverProvesHandoverAndEchoesSwitchover()
    {
        using var fake = new FakeReceiver { OpenAdmission = true };
        fake.Start();

        // Open a dummy main session so FakeReceiver has admitted state / token.
        {
            var main = await Connection.ConnectAsync("127.0.0.1", fake.Port, TimeSpan.FromSeconds(3));
            main.OnMessage = _ => { };
            main.Start();
            main.Send(JsonWire.Message(MessageType.Hello, new Hello
            {
                ProtocolVersion = AfterscreenProtocol.Version,
                Name = "t",
                SenderID = "handover-test",
            }));
            for (var i = 0; i < 50 && fake.State != "admitted" && !fake.State.StartsWith("error"); i++)
                await Task.Delay(50);
            Assert.Equal("admitted", fake.State);
            // Keep main open while handing over.
            _ = main;
        }

        var secret = Handover.Secret(null, fake.HandoverToken);
        var senderNonce = Pairing.Nonce();
        var c = await Connection.ConnectAsync("127.0.0.1", fake.Port, TimeSpan.FromSeconds(3));
        var challenge = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var ok = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var switched = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        c.OnMessage = m =>
        {
            switch (m.Type)
            {
                case MessageType.HandoverChallenge:
                    challenge.TrySetResult(JsonWire.Decode<HandoverNonce>(m.Payload).Nonce);
                    break;
                case MessageType.HandoverOK:
                    ok.TrySetResult();
                    break;
                case MessageType.Switchover:
                    switched.TrySetResult();
                    break;
                case MessageType.ProbeResult:
                    break;
            }
        };
        c.Start();
        c.Send(JsonWire.Message(MessageType.Handover, new HandoverNonce { Nonce = senderNonce }));
        var receiverNonce = await challenge.Task.WaitAsync(TimeSpan.FromSeconds(3));
        c.Send(JsonWire.Message(MessageType.HandoverProof, new AuthProof
        {
            Mac = Handover.Proof(secret, Handover.Role.Sender, senderNonce, receiverNonce),
        }));
        await ok.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.True(fake.Handovers >= 1);

        // Minimal probe end so the handoff path can measure.
        c.Send(new Message(MessageType.Probe, ProbeFlags.End, Array.Empty<byte>()));
        c.Send(new Message(MessageType.Switchover));
        await switched.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal("switched", fake.State);
        c.Dispose();
    }
}
