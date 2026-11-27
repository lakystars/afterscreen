namespace Afterscreen.Protocol;

public enum MessageType : byte
{
    Hello = 0x01,
    Welcome = 0x02,
    Config = 0x03,
    Auth = 0x04,
    AuthOK = 0x05,
    Pair = 0x06,
    Paired = 0x07,
    PairWrong = 0x08,
    Handover = 0x09,
    HandoverChallenge = 0x0A,
    HandoverProof = 0x0B,
    HandoverOK = 0x0C,
    Switchover = 0x0D,
    Reconfigure = 0x0E,
    TileFrame = 0x10,
    VideoParams = 0x11,
    VideoFrame = 0x12,
    CursorPos = 0x20,
    CursorImage = 0x21,
    Brightness = 0x22,
    CursorChannel = 0x23,
    Audio = 0x24,
    Volume = 0x25,
    Deband = 0x26,
    PowerOff = 0x27,
    ReceiverOptions = 0x28,
    SetReceiverOptions = 0x29,
    Probe = 0x30,
    ProbeResult = 0x31,
    Ping = 0x40,
    Pong = 0x41,
    Stats = 0x50,
    SenderStats = 0x51,
    KeyRequest = 0x60,
    Bye = 0x7F,
}

public readonly struct Message
{
    public MessageType Type { get; }
    public byte Flags { get; }
    public byte[] Payload { get; }

    public Message(MessageType type, byte flags = 0, byte[]? payload = null)
    {
        Type = type;
        Flags = flags;
        Payload = payload ?? Array.Empty<byte>();
    }
}

public sealed class FramingException : Exception
{
    public FramingException(string message) : base(message) { }
}

/// <summary>Little-endian header: u8 type, u8 flags, u16 reserved, u32 payload length.</summary>
public static class Framing
{
    public const int HeaderSize = 8;
    public const int MaxPayload = 64 << 20;

    public static byte[] Header(MessageType type, byte flags, int length)
    {
        var buf = new byte[HeaderSize];
        buf[0] = (byte)type;
        buf[1] = flags;
        BinaryPrimitivesWriteUInt32LittleEndian(buf.AsSpan(4), (uint)length);
        return buf;
    }

    public static byte[] Encode(Message message)
    {
        var header = Header(message.Type, message.Flags, message.Payload.Length);
        var frame = new byte[HeaderSize + message.Payload.Length];
        header.CopyTo(frame, 0);
        message.Payload.CopyTo(frame, HeaderSize);
        return frame;
    }

    public static Message Decode(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < HeaderSize)
            throw new FramingException("truncated");
        var typeByte = frame[0];
        if (!Enum.IsDefined(typeof(MessageType), typeByte))
            throw new FramingException($"unknownType:{typeByte}");
        var flags = frame[1];
        var length = BinaryPrimitivesReadUInt32LittleEndian(frame.Slice(4));
        if (length > MaxPayload)
            throw new FramingException($"oversized:{length}");
        if (frame.Length < HeaderSize + length)
            throw new FramingException("truncated");
        var payload = frame.Slice(HeaderSize, (int)length).ToArray();
        return new Message((MessageType)typeByte, flags, payload);
    }

    private static void BinaryPrimitivesWriteUInt32LittleEndian(Span<byte> destination, uint value)
    {
        destination[0] = (byte)value;
        destination[1] = (byte)(value >> 8);
        destination[2] = (byte)(value >> 16);
        destination[3] = (byte)(value >> 24);
    }

    private static uint BinaryPrimitivesReadUInt32LittleEndian(ReadOnlySpan<byte> source) =>
        (uint)(source[0] | (source[1] << 8) | (source[2] << 16) | (source[3] << 24));
}

public sealed class FrameReader
{
    private readonly Stream _source;
    private readonly byte[] _ahead = new byte[64 << 10];
    private int _start;
    private int _end;

    public FrameReader(Stream source) => _source = source;

    public Message? Next()
    {
        if (!Fill(Framing.HeaderSize, endOk: true))
            return null;

        var typeByte = _ahead[_start];
        var flags = _ahead[_start + 1];
        var length = (int)(_ahead[_start + 4]
            | ((uint)_ahead[_start + 5] << 8)
            | ((uint)_ahead[_start + 6] << 16)
            | ((uint)_ahead[_start + 7] << 24));
        if (length > Framing.MaxPayload)
            throw new FramingException($"oversized:{length}");
        if (!Enum.IsDefined(typeof(MessageType), typeByte))
            throw new FramingException($"unknownType:{typeByte}");
        _start += Framing.HeaderSize;

        var payload = new byte[length];
        var have = Math.Min(_end - _start, length);
        Buffer.BlockCopy(_ahead, _start, payload, 0, have);
        _start += have;
        var got = have;
        while (got < length)
        {
            var n = _source.Read(payload, got, length - got);
            if (n <= 0)
                throw new FramingException("truncated");
            got += n;
        }

        return new Message((MessageType)typeByte, flags, payload);
    }

    private bool Fill(int count, bool endOk)
    {
        if (_end - _start >= count)
            return true;
        if (_start > 0)
        {
            Buffer.BlockCopy(_ahead, _start, _ahead, 0, _end - _start);
            _end -= _start;
            _start = 0;
        }

        while (_end < count)
        {
            var n = _source.Read(_ahead, _end, _ahead.Length - _end);
            if (n == 0)
            {
                if (endOk && _end == 0)
                    return false;
                throw new FramingException("truncated");
            }
            _end += n;
        }
        return true;
    }
}
