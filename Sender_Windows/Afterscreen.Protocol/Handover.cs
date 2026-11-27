using System.Security.Cryptography;
using System.Text;

namespace Afterscreen.Protocol;

/// <summary>
/// Mac <c>Handover</c>: a second connection taking over a running session.
/// Secret is the pairing key HMAC'd with the session token, or SHA256 of the label+token when unpaired.
/// Both sides prove over fresh nonces; the token stays on the receiver.
/// </summary>
public static class Handover
{
    private static readonly byte[] Label = Encoding.UTF8.GetBytes("afterscreen handover");

    public enum Role
    {
        Sender,
        Receiver,
    }

    private static string RoleLabel(Role role) => role switch
    {
        Role.Sender => "handover-sender",
        Role.Receiver => "handover-receiver",
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };

    /// <param name="key">Session pairing key; null when admitted without one.</param>
    public static byte[] Secret(byte[]? key, byte[] token)
    {
        if (key is null)
        {
            var open = new byte[Label.Length + token.Length];
            Buffer.BlockCopy(Label, 0, open, 0, Label.Length);
            Buffer.BlockCopy(token, 0, open, Label.Length, token.Length);
            return SHA256.HashData(open);
        }
        using var hmac = new HMACSHA256(key);
        hmac.TransformBlock(Label, 0, Label.Length, null, 0);
        hmac.TransformFinalBlock(token, 0, token.Length);
        return hmac.Hash!;
    }

    public static byte[] Proof(byte[] secret, Role role, byte[] senderNonce, byte[] receiverNonce)
    {
        using var hmac = new HMACSHA256(secret);
        var roleBytes = Encoding.UTF8.GetBytes(RoleLabel(role));
        hmac.TransformBlock(roleBytes, 0, roleBytes.Length, null, 0);
        hmac.TransformBlock(senderNonce, 0, senderNonce.Length, null, 0);
        hmac.TransformFinalBlock(receiverNonce, 0, receiverNonce.Length);
        return hmac.Hash!;
    }
}
