using Afterscreen.Sender.Encode;
using Xunit;
using Xunit.Abstractions;

namespace Afterscreen.Sender.Tests;

public class Lz4AndPolicyTests
{
    private readonly ITestOutputHelper _out;
    public Lz4AndPolicyTests(ITestOutputHelper output) => _out = output;

    private static void RoundTrip(byte[] data, out int size)
    {
        var buf = new byte[Lz4.Bound(data.Length)];
        size = Lz4.Compress(data, buf);
        var back = new byte[data.Length];
        Assert.True(Lz4.Decompress(buf.AsSpan(0, size), back), "decode failed");
        Assert.Equal(data, back);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(11)]
    [InlineData(13)]
    [InlineData(100)]
    [InlineData(70000)]
    [InlineData(1 << 20)]
    public void RepetitiveDataRoundTripsAndShrinks(int n)
    {
        var data = new byte[n];
        for (var i = 0; i < n; i++) data[i] = (byte)((i / 16) % 7 == 0 ? 0xAB : (i % 5));
        RoundTrip(data, out var size);
        _out.WriteLine($"{n} -> {size}");
        if (n >= 100) Assert.True(size < n / 2);
    }

    [Fact]
    public void RandomDataRoundTrips()
    {
        var data = new byte[300_000];
        new Random(1).NextBytes(data);
        RoundTrip(data, out var size);
        Assert.True(size <= Lz4.Bound(data.Length));
    }

    [Fact]
    public void PolicyStoresWhenTheFrameFitsAndCompressesWhenBigOrCongested()
    {
        var p = new CompressionPolicy(1.0, 60);
        Assert.Equal(TileCompression.None, p.Next(100_000, false));      // 100 KB * 8 * 60 * 1.3 = 62 Mbit/s
        Assert.Equal(TileCompression.All, p.Next(2_000_000, false));     // 1.25 Gbit/s > 1 Gbit/s
        Assert.Equal(TileCompression.All, p.Next(100_000, true));        // congested
        Assert.Equal(TileCompression.All, p.Next(100_000, false));       // stays congested for a while
    }

    [Fact]
    public void IncompressibleContentIsOnlyProbed()
    {
        var p = new CompressionPolicy(0.1, 60);
        Assert.Equal(TileCompression.All, p.Next(2_000_000, false));
        p.Record(2_000_000, 1_900_000);                                  // ratio 1.05 < 1.25
        var probes = 0;
        for (var i = 0; i < CompressionPolicy.ProbeInterval; i++)
            if (p.Next(2_000_000, false) == TileCompression.FirstChunk) probes++;
        Assert.Equal(1, probes);
    }
}
