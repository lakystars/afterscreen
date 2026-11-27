using System.Security.Cryptography;
using System.Text;
using NSec.Cryptography;

namespace Afterscreen.Protocol;

/// <summary>
/// Network pairing: X25519 + HKDF-SHA256 + HMAC (matches Core Pairing.swift).
/// </summary>
public static class Pairing
{
    private static readonly byte[] SharedInfo = Encoding.UTF8.GetBytes("afterscreen pairing");

    public sealed class KeyPair : IDisposable
    {
        private readonly Key _privateKey;

        public KeyPair(Key privateKey) => _privateKey = privateKey;

        public byte[] PublicKey => _privateKey.PublicKey.Export(KeyBlobFormat.RawPublicKey);

        public Key PrivateKey => _privateKey;

        public void Dispose() => _privateKey.Dispose();
    }

    public sealed class Transcript
    {
        public string SenderID { get; set; }
        public string ReceiverID { get; set; }
        public byte[] SenderNonce { get; set; }
        public byte[] ReceiverNonce { get; set; }
        public byte[] SenderKey { get; set; } = Array.Empty<byte>();
        public byte[] ReceiverKey { get; set; } = Array.Empty<byte>();

        public Transcript(string senderID, string receiverID, byte[] senderNonce, byte[] receiverNonce,
            byte[]? senderKey = null, byte[]? receiverKey = null)
        {
            SenderID = senderID;
            ReceiverID = receiverID;
            SenderNonce = senderNonce;
            ReceiverNonce = receiverNonce;
            SenderKey = senderKey ?? Array.Empty<byte>();
            ReceiverKey = receiverKey ?? Array.Empty<byte>();
        }

        /// <summary>Length-prefixed parts (big-endian length), same as Swift.</summary>
        public byte[] Bytes
        {
            get
            {
                var parts = new[]
                {
                    Encoding.UTF8.GetBytes(SenderID),
                    Encoding.UTF8.GetBytes(ReceiverID),
                    SenderNonce,
                    ReceiverNonce,
                    SenderKey,
                    ReceiverKey,
                };
                using var ms = new MemoryStream();
                foreach (var part in parts)
                {
                    var n = BitConverter.GetBytes(System.Net.IPAddress.HostToNetworkOrder(part.Length));
                    ms.Write(n, 0, 4);
                    ms.Write(part, 0, part.Length);
                }
                return ms.ToArray();
            }
        }
    }

    public enum Role
    {
        Sender,
        Receiver,
    }

    public static string RoleLabel(Role role) => role switch
    {
        Role.Sender => "auth-sender",
        Role.Receiver => "auth-receiver",
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };

    public static byte[] Nonce()
    {
        var bytes = new byte[16];
        RandomNumberGenerator.Fill(bytes);
        return bytes;
    }

    public static string Code()
    {
        Span<byte> raw = stackalloc byte[4];
        RandomNumberGenerator.Fill(raw);
        var value = BitConverter.ToUInt32(raw) % 1_000_000u;
        return value.ToString("D6");
    }

    public static KeyPair NewKey()
    {
        var key = Key.Create(KeyAgreementAlgorithm.X25519,
            new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });
        return new KeyPair(key);
    }

    public static byte[] SessionKey(KeyPair own, byte[] peerPublic, Transcript transcript)
    {
        var peer = PublicKey.Import(KeyAgreementAlgorithm.X25519, peerPublic, KeyBlobFormat.RawPublicKey);
        using var shared = KeyAgreementAlgorithm.X25519.Agree(own.PrivateKey, peer)
            ?? throw new CryptographicException("X25519 agreement failed");

        // CryptoKit SharedSecret.hkdfDerivedSymmetricKey(SHA256, salt=transcript, info, 32)
        return KeyDerivationAlgorithm.HkdfSha256.DeriveBytes(
            shared,
            salt: transcript.Bytes,
            info: SharedInfo,
            count: 32);
    }

    public static byte[] Confirm(byte[] session, string code, Transcript transcript) =>
        Mac(session, "pair-confirm", transcript, Encoding.UTF8.GetBytes(code));

    public static byte[] PairedProof(byte[] session, Transcript transcript) =>
        Mac(session, "pair-done", transcript);

    public static byte[] PairingKey(byte[] session, string code, Transcript transcript) =>
        Mac(session, "pairing-key", transcript, Encoding.UTF8.GetBytes(code));

    public static byte[] Proof(byte[] key, Role role, Transcript transcript) =>
        Mac(key, RoleLabel(role), transcript);

    public static bool Matches(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        if (a.Length != b.Length)
            return false;
        var diff = 0;
        for (var i = 0; i < a.Length; i++)
            diff |= a[i] ^ b[i];
        return diff == 0;
    }

    private static byte[] Mac(byte[] key, string label, Transcript transcript, byte[]? extra = null)
    {
        using var hmac = new HMACSHA256(key);
        hmac.TransformBlock(Encoding.UTF8.GetBytes(label), 0, label.Length, null, 0);
        var t = transcript.Bytes;
        hmac.TransformBlock(t, 0, t.Length, null, 0);
        var e = extra ?? Array.Empty<byte>();
        hmac.TransformFinalBlock(e, 0, e.Length);
        return hmac.Hash!;
    }
}
