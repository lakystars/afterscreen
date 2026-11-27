using System.Text.Json;
using System.Text.Json.Serialization;

namespace Afterscreen.Protocol;

public static class AfterscreenProtocol
{
    public const int Version = 11;
    public const string BonjourType = "_afterscreen._tcp";
}

public sealed class PixelSize
{
    public int Width { get; set; }
    public int Height { get; set; }

    public PixelSize() { }
    public PixelSize(int width, int height)
    {
        Width = width;
        Height = height;
    }
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum LinkKind
{
    thunderbolt,
    usb,
    ethernet,
    wifi,
    loopback,
    unsupported,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum StreamPath
{
    tile,
    hybrid,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum VideoCodec
{
    hevc,
    h264,
}

public sealed class Hello
{
    public int ProtocolVersion { get; set; }
    public string Name { get; set; } = "";
    public string Model { get; set; } = "";
    public string OsVersion { get; set; } = "";
    public string? SenderID { get; set; }
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[]? Nonce { get; set; }
    public bool? Paired { get; set; }
    public bool? Repair { get; set; }
    public bool? ReadsOptions { get; set; }
}

public enum AuthMode
{
    paired,
    pair,
}

public sealed class AuthChallenge
{
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public AuthMode Mode { get; set; }

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[] Nonce { get; set; } = Array.Empty<byte>();

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[]? PublicKey { get; set; }
}

/// <summary>Mac <c>HandoverNonce</c>: opens a handover, or answers one.</summary>
public sealed class HandoverNonce
{
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[] Nonce { get; set; } = Array.Empty<byte>();
}

public sealed class AuthProof
{
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[] Mac { get; set; } = Array.Empty<byte>();
}

public sealed class PairConfirm
{
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[] PublicKey { get; set; } = Array.Empty<byte>();

    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[] Mac { get; set; } = Array.Empty<byte>();
}

public sealed class Welcome
{
    public int ProtocolVersion { get; set; }
    public string Name { get; set; } = "";
    public string ModelID { get; set; } = "";
    public string MarketingName { get; set; } = "";
    public string OsVersion { get; set; } = "";
    public List<string> GpuNames { get; set; } = new();
    public PixelSize PanelPixels { get; set; } = new();
    public PixelSize PanelPoints { get; set; } = new();
    public bool HevcDecode { get; set; }
    public bool H264Decode { get; set; }
    public bool Bc7 { get; set; }
    public bool HevcMain10Decode { get; set; }
    public bool AudioPlayback { get; set; }
    public uint ChannelToken { get; set; }
    public string? ReceiverID { get; set; }
    public AuthChallenge? Auth { get; set; }
    public PixelSize? PanelMillimeters { get; set; }
    public double? RefreshHz { get; set; }
    [JsonConverter(typeof(Base64ByteArrayConverter))]
    public byte[]? HandoverToken { get; set; }
    public string? AppVersion { get; set; }

    [JsonIgnore]
    public double FrameRate => Math.Min(240, Math.Max(24, RefreshHz ?? 60));
}

public sealed class VideoLayer
{
    public VideoCodec Codec { get; set; }
    public PixelSize Pixels { get; set; } = new();
    public int Bitrate { get; set; }
    public bool TenBit { get; set; }
}

public sealed class StreamConfig
{
    public StreamPath Path { get; set; }
    public PixelSize StreamPixels { get; set; } = new();
    public VideoLayer? Video { get; set; }
    public LinkKind LinkKind { get; set; }
    public bool Test { get; set; }
    public double FrameRate { get; set; } = 60;
}

/// <summary>Mac <c>ReceiverPower</c>: receiver Mac once a session ends.</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ReceiverPower { keepOn, sleep, shutDown }

public sealed class Bye
{
    public string Reason { get; set; } = "";
    public bool Pause { get; set; }
    public bool Relink { get; set; }
    public bool? Repair { get; set; }
    /// <summary>Sender's request; heeded from paired or cabled senders.</summary>
    public ReceiverPower? Power { get; set; }
    public bool? Reopen { get; set; }
}

public sealed class ProbeResult
{
    public int Bytes { get; set; }
    public double Seconds { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public double Gbps => Seconds > 0 ? Bytes * 8.0 / Seconds / 1e9 : 0;
}

/// <summary>Mac <c>SenderStats</c> — once a second; Receiver HUD Picture card.</summary>
public sealed class SenderStats
{
    public string? Interface { get; set; }
    public double? CapacityGbps { get; set; }
    public double ThroughputBitsPerSecond { get; set; }
    public double? LatencyMs { get; set; }
    public double JitterMs { get; set; }
    public double RetransmitPercent { get; set; }
    public int? CableScore { get; set; }
    // Swift Codable keeps "FPS" capitals — override camelCase.
    [JsonPropertyName("captureFPS")]
    public double CaptureFPS { get; set; }
    [JsonPropertyName("sentFPS")]
    public double SentFPS { get; set; }
    public int DroppedPerMinute { get; set; }
    public double DirtyPercent { get; set; }
    public double CompressionRatio { get; set; }
    public double EncodeMs { get; set; }
    public int LossyTiles { get; set; }
    public double CpuPercent { get; set; }
    public ulong MemoryBytes { get; set; }
    public double GpuPercent { get; set; }
    public int? VideoBitrate { get; set; }
    public bool? CongestionNotice { get; set; }
    public bool? FlashBlocks { get; set; }
    public string? Language { get; set; }
}

public static class ChannelWire
{
    public static byte[] Encode(uint token)
    {
        var w = new ByteWriter(4);
        w.U32(token);
        return w.ToArray();
    }
}

public static class CursorWire
{
    public static byte[] Pos(float x, float y, bool visible)
    {
        var w = new ByteWriter(9);
        w.F32(x);
        w.F32(y);
        w.U8(visible ? (byte)1 : (byte)0);
        return w.ToArray();
    }

    public static byte[] Image(int width, int height, int hotX, int hotY, ReadOnlySpan<byte> png)
    {
        var w = new ByteWriter(8 + png.Length);
        w.U16((ushort)Math.Clamp(width, 0, 65535));
        w.U16((ushort)Math.Clamp(height, 0, 65535));
        w.U16((ushort)Math.Clamp(hotX, 0, 65535));
        w.U16((ushort)Math.Clamp(hotY, 0, 65535));
        w.Bytes(png);
        return w.ToArray();
    }
}

public static class JsonWire
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
    };

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Decode<T>(ReadOnlySpan<byte> data) =>
        JsonSerializer.Deserialize<T>(data, Options)
        ?? throw new InvalidOperationException($"JSON decode returned null for {typeof(T).Name}");

    public static Message Message<T>(MessageType type, T value) =>
        new(type, payload: Encode(value));
}

/// <summary>Swift Codable Data ↔ base64 string.</summary>
public sealed class Base64ByteArrayConverter : JsonConverter<byte[]?>
{
    public override byte[]? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
            return null;
        var s = reader.GetString();
        return s is null ? null : Convert.FromBase64String(s);
    }

    public override void Write(Utf8JsonWriter writer, byte[]? value, JsonSerializerOptions options)
    {
        if (value is null)
            writer.WriteNullValue();
        else
            writer.WriteStringValue(Convert.ToBase64String(value));
    }
}
