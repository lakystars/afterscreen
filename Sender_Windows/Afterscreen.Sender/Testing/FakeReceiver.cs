using System.Net;
using System.Net.Sockets;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Testing;

/// <summary>Local stand-in for Mac Receiver: pair/paired + probe + accept stream frames.</summary>
public sealed class FakeReceiver : IDisposable
{
    private readonly TcpListener _listener;
    private readonly string _receiverId;
    private readonly IPairingStore _store;
    private readonly byte[] _handoverToken = Pairing.Nonce();
    private byte[]? _handoverKey; // pairing key once admitted; null = open-session secret
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public int Port { get; }
    public string ReceiverId => _receiverId;
    public byte[] HandoverToken => _handoverToken;
    public string? ShownCode { get; private set; }
    public int TileFrames { get; private set; }
    public int VideoFrames { get; private set; }
    public int AudioMessages { get; private set; }
    public int Configs { get; private set; }
    public int Handovers { get; private set; }
    public StreamConfig? LastConfig { get; private set; }
    public string State { get; private set; } = "listening";
    /// <summary>When true, Welcome has no Auth (cable-style open session) so handover uses the token-only secret.</summary>
    public bool OpenAdmission { get; set; }

    public FakeReceiver(int port = 0, IPairingStore? store = null)
    {
        _store = store ?? new MemoryPairingStore();
        _receiverId = "fake-receiver-" + Guid.NewGuid().ToString("N")[..8];
        _listener = new TcpListener(IPAddress.Loopback, port);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _acceptLoop = Task.Run(() => AcceptLoop(_cts.Token));
    }

    private async Task AcceptLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
            }
            catch when (ct.IsCancellationRequested)
            {
                return;
            }

            _ = Task.Run(() => HandleClient(client), ct);
        }
    }

    private void HandleClient(TcpClient client)
    {
        try
        {
            using var _ = client;
            var stream = client.GetStream();
            var reader = new FrameReader(stream);
            Hello? hello = null;
            Pairing.KeyPair? ephemeral = null;
            byte[]? receiverNonce = null;
            string? pendingCode = null;
            byte[]? sessionKey = null;
            Pairing.Transcript? transcript = null;
            long probeBytes = 0;
            var probeWatch = System.Diagnostics.Stopwatch.StartNew();

            while (true)
            {
                var msg = reader.Next();
                if (msg is null)
                    break;

                switch (msg.Value.Type)
                {
                    case MessageType.CursorChannel:
                        // Second TCP from the sender (cursor/audio); stay up and ignore later payloads.
                        State = "cursor-channel";
                        break;
                    case MessageType.Handover:
                    {
                        // Second TCP taking over a running session (Mac offerChannel handover path).
                        var req = JsonWire.Decode<HandoverNonce>(msg.Value.Payload);
                        if (req.Nonce.Length != 16) { State = "handover-bad"; return; }
                        var secret = Handover.Secret(_handoverKey, _handoverToken);
                        var challengeNonce = Pairing.Nonce();
                        Write(stream, JsonWire.Message(MessageType.HandoverChallenge, new HandoverNonce { Nonce = challengeNonce }));
                        var proofMsg = reader.Next();
                        if (proofMsg is null || proofMsg.Value.Type != MessageType.HandoverProof)
                        {
                            State = "handover-no-proof";
                            return;
                        }
                        var proof = JsonWire.Decode<AuthProof>(proofMsg.Value.Payload);
                        var expect = Handover.Proof(secret, Handover.Role.Sender, req.Nonce, challengeNonce);
                        if (!Pairing.Matches(proof.Mac, expect))
                        {
                            Write(stream, JsonWire.Message(MessageType.Bye, new Bye { Reason = "handover proof" }));
                            State = "handover-fail";
                            return;
                        }
                        Write(stream, JsonWire.Message(MessageType.HandoverOK, new AuthProof
                        {
                            Mac = Handover.Proof(secret, Handover.Role.Receiver, req.Nonce, challengeNonce),
                        }));
                        Handovers++;
                        State = "handover-proven";
                        // Stay on this connection for probe / switchover / stream.
                        break;
                    }
                    case MessageType.Switchover:
                        Write(stream, new Message(MessageType.Switchover));
                        State = "switched";
                        break;
                    case MessageType.Hello:
                    {
                        hello = JsonWire.Decode<Hello>(msg.Value.Payload);
                        State = "hello";
                        AuthChallenge? auth = null;
                        receiverNonce = Pairing.Nonce();
                        if (!OpenAdmission)
                        {
                            var kept = hello.SenderID is not null ? _store.Key(hello.SenderID) : null;
                            if (kept is not null && hello.Paired == true && hello.Repair != true)
                            {
                                auth = new AuthChallenge { Mode = AuthMode.paired, Nonce = receiverNonce };
                            }
                            else
                            {
                                ephemeral = Pairing.NewKey();
                                ShownCode = Pairing.Code();
                                pendingCode = ShownCode;
                                auth = new AuthChallenge
                                {
                                    Mode = AuthMode.pair,
                                    Nonce = receiverNonce,
                                    PublicKey = ephemeral.PublicKey,
                                };
                                Console.WriteLine($"[fake-receiver] pairing code: {ShownCode}");
                            }
                        }

                        var welcome = new Welcome
                        {
                            ProtocolVersion = AfterscreenProtocol.Version,
                            Name = "FakeReceiver",
                            ModelID = "Fake1,1",
                            MarketingName = "Fake iMac",
                            OsVersion = "15.0",
                            GpuNames = new List<string> { "FakeGPU" },
                            PanelPixels = new PixelSize(5120, 2880),
                            PanelPoints = new PixelSize(2560, 1440),
                            HevcDecode = true,
                            H264Decode = true,
                            Bc7 = true,
                            HevcMain10Decode = true,
                            AudioPlayback = true,
                            ChannelToken = 1,
                            ReceiverID = _receiverId,
                            Auth = auth,
                            HandoverToken = _handoverToken,
                            RefreshHz = 60,
                            AppVersion = "0.0-fake",
                        };
                        Write(stream, JsonWire.Message(MessageType.Welcome, welcome));
                        if (auth is null) { State = "admitted"; }
                        else State = auth.Mode == AuthMode.pair ? "await-pair" : "await-auth";
                        break;
                    }
                    case MessageType.Auth:
                    {
                        if (hello?.SenderID is null || receiverNonce is null)
                            break;
                        var kept = _store.Key(hello.SenderID);
                        if (kept is null)
                        {
                            Write(stream, JsonWire.Message(MessageType.Bye, new Bye { Reason = "no key" }));
                            return;
                        }
                        var proof = JsonWire.Decode<AuthProof>(msg.Value.Payload);
                        var t = new Pairing.Transcript(hello.SenderID, _receiverId, hello.Nonce ?? Array.Empty<byte>(), receiverNonce);
                        var expect = Pairing.Proof(kept, Pairing.Role.Sender, t);
                        if (!Pairing.Matches(proof.Mac, expect))
                        {
                            Write(stream, JsonWire.Message(MessageType.Bye, new Bye { Reason = "auth fail", Repair = true }));
                            return;
                        }
                        var back = Pairing.Proof(kept, Pairing.Role.Receiver, t);
                        _handoverKey = kept;
                        Write(stream, JsonWire.Message(MessageType.AuthOK, new AuthProof { Mac = back }));
                        State = "admitted";
                        break;
                    }
                    case MessageType.Pair:
                    {
                        if (hello?.SenderID is null || ephemeral is null || receiverNonce is null || pendingCode is null)
                            break;
                        var confirm = JsonWire.Decode<PairConfirm>(msg.Value.Payload);
                        transcript = new Pairing.Transcript(
                            hello.SenderID, _receiverId, hello.Nonce ?? Array.Empty<byte>(), receiverNonce,
                            confirm.PublicKey, ephemeral.PublicKey);
                        sessionKey = Pairing.SessionKey(ephemeral, confirm.PublicKey, transcript);
                        var expect = Pairing.Confirm(sessionKey, pendingCode, transcript);
                        if (!Pairing.Matches(confirm.Mac, expect))
                        {
                            Write(stream, new Message(MessageType.PairWrong));
                            State = "await-pair";
                            break;
                        }
                        var pairingKey = Pairing.PairingKey(sessionKey, pendingCode, transcript);
                        _store.Save(pairingKey, hello.SenderID, hello.Name);
                        _handoverKey = pairingKey;
                        var done = Pairing.PairedProof(sessionKey, transcript);
                        Write(stream, JsonWire.Message(MessageType.Paired, new AuthProof { Mac = done }));
                        ShownCode = null;
                        State = "admitted";
                        break;
                    }
                    case MessageType.Probe:
                        probeBytes += msg.Value.Payload.Length;
                        if ((msg.Value.Flags & ProbeFlags.End) != 0)
                        {
                            probeWatch.Stop();
                            var seconds = Math.Max(probeWatch.Elapsed.TotalSeconds, 0.001);
                            Write(stream, JsonWire.Message(MessageType.ProbeResult, new ProbeResult
                            {
                                Bytes = (int)Math.Min(int.MaxValue, probeBytes),
                                Seconds = seconds,
                            }));
                            State = "probed";
                        }
                        break;
                    case MessageType.Config:
                        LastConfig = JsonWire.Decode<StreamConfig>(msg.Value.Payload);
                        Configs++;
                        State = "streaming";
                        Console.WriteLine($"[fake-receiver] config path={LastConfig.Path} {LastConfig.StreamPixels.Width}x{LastConfig.StreamPixels.Height} fps={LastConfig.FrameRate}");
                        break;
                    case MessageType.TileFrame:
                        TileFrames++;
                        break;
                    case MessageType.Audio:
                    case MessageType.Volume:
                        AudioMessages++;
                        break;
                    case MessageType.VideoFrame:
                        VideoFrames++;
                        break;
                    case MessageType.VideoParams:
                        break;
                    case MessageType.Bye:
                        State = "bye";
                        return;
                    default:
                        break;
                }
            }
        }
        catch (Exception ex)
        {
            State = "error:" + ex.Message;
        }
    }

    private static void Write(NetworkStream stream, Message message)
    {
        var frame = Framing.Encode(message);
        stream.Write(frame, 0, frame.Length);
        stream.Flush();
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _listener.Stop(); } catch { /* ignore */ }
        ephemeralDispose();
    }

    private void ephemeralDispose() { /* keys disposed per-connection */ }
}
