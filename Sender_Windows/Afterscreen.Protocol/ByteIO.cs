namespace Afterscreen.Protocol;

public sealed class ByteWriter
{
    private readonly MemoryStream _ms;

    public ByteWriter(int capacity = 64) => _ms = new MemoryStream(capacity);

    public int Length => (int)_ms.Length;

    public void U8(byte v) => _ms.WriteByte(v);
    public void U16(ushort v)
    {
        _ms.WriteByte((byte)v);
        _ms.WriteByte((byte)(v >> 8));
    }
    public void U32(uint v)
    {
        _ms.WriteByte((byte)v);
        _ms.WriteByte((byte)(v >> 8));
        _ms.WriteByte((byte)(v >> 16));
        _ms.WriteByte((byte)(v >> 24));
    }
    public void U64(ulong v)
    {
        U32((uint)v);
        U32((uint)(v >> 32));
    }
    public void F32(float v) => U32(BitConverter.SingleToUInt32Bits(v));
    public void Bytes(ReadOnlySpan<byte> data) => _ms.Write(data);

    public byte[] ToArray() => _ms.ToArray();
}

public ref struct ByteReader
{
    private readonly ReadOnlySpan<byte> _data;
    public int Position { get; private set; }

    public ByteReader(ReadOnlySpan<byte> data)
    {
        _data = data;
        Position = 0;
    }

    public int Remaining => _data.Length - Position;

    private ReadOnlySpan<byte> Take(int n)
    {
        if (n < 0 || Remaining < n)
            throw new FramingException("truncated");
        var s = _data.Slice(Position, n);
        Position += n;
        return s;
    }

    public byte U8() => Take(1)[0];

    public ushort U16()
    {
        var s = Take(2);
        return (ushort)(s[0] | (s[1] << 8));
    }

    public uint U32()
    {
        var s = Take(4);
        return (uint)(s[0] | (s[1] << 8) | (s[2] << 16) | (s[3] << 24));
    }

    public ulong U64()
    {
        var lo = U32();
        var hi = U32();
        return lo | ((ulong)hi << 32);
    }

    public ReadOnlySpan<byte> Rest()
    {
        var s = _data.Slice(Position);
        Position = _data.Length;
        return s;
    }
}
