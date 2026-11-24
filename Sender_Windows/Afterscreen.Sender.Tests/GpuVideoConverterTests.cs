using Afterscreen.Sender.Capture;
using Afterscreen.Sender.Encode;
using Xunit;
using Xunit.Abstractions;

namespace Afterscreen.Sender.Tests;

/// <summary>GPU BGRA to NV12/P010 conversion must agree with the CPU reference (same BT.709 video-range maths).</summary>
public class GpuVideoConverterTests
{
    private readonly ITestOutputHelper _out;
    public GpuVideoConverterTests(ITestOutputHelper output) => _out = output;

    private static byte[] Picture(int w, int h)
    {
        var b = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var i = (y * w + x) * 4;
                // smooth gradients (so 2x2 chroma averaging is comparable) plus a flat colour block
                var flat = x >= w / 2 && y >= h / 2;
                b[i] = (byte)(flat ? 200 : x * 255 / w);
                b[i + 1] = (byte)(flat ? 40 : y * 255 / h);
                b[i + 2] = (byte)(flat ? 90 : (x + y) * 255 / (w + h));
                b[i + 3] = 255;
            }
        return b;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void MatchesCpuReference(bool tenBit)
    {
        const int w = 256, h = 128;
        using var dev = D3dEncodeDevice.TryCreate();
        if (dev is null) return;                       // no GPU on this machine
        using var frame = new GpuFrame(dev.Device, w, h);
        var bgra = Picture(w, h);
        frame.Upload(dev.Context, bgra);
        using var conv = new GpuVideoConverter(dev, w, h, tenBit);
        var gpu = new byte[conv.OutputBytes];
        conv.Convert(frame, gpu);

        var cpu = new byte[conv.OutputBytes];
        if (tenBit) MfH264Encoder.BgraToP010(bgra, w, h, cpu);
        else MfH264Encoder.BgraToNv12(bgra, w, h, cpu);

        double sum = 0; int max = 0;
        if (tenBit)
            for (var i = 0; i < cpu.Length; i += 2)
            {
                var a = (cpu[i] | cpu[i + 1] << 8) >> 6;
                var g = (gpu[i] | gpu[i + 1] << 8) >> 6;
                var d = Math.Abs(a - g); sum += d; max = Math.Max(max, d);
            }
        else
            for (var i = 0; i < cpu.Length; i++)
            {
                var d = Math.Abs(cpu[i] - gpu[i]); sum += d; max = Math.Max(max, d);
            }
        for (var k = 0; k < 6; k++)
            _out.WriteLine($"  [{k}] cpu {(tenBit ? (cpu[k*2] | cpu[k*2+1] << 8) >> 6 : cpu[k])} gpu {(tenBit ? (gpu[k*2] | gpu[k*2+1] << 8) >> 6 : gpu[k])}");
        var yEnd = w * h;
        _out.WriteLine($"  uv0 cpu {(tenBit ? (cpu[yEnd*2] | cpu[yEnd*2+1] << 8) >> 6 : cpu[yEnd])} gpu {(tenBit ? (gpu[yEnd*2] | gpu[yEnd*2+1] << 8) >> 6 : gpu[yEnd])}");
        var n = tenBit ? cpu.Length / 2 : cpu.Length;
        var mean = sum / n;
        _out.WriteLine($"tenBit={tenBit}: mean abs diff {mean:0.00}, max {max} (code values)");
        Assert.True(mean < (tenBit ? 3.0 : 0.8), $"mean diff {mean}");
        Assert.True(max < (tenBit ? 80 : 40), $"max diff {max}");
    }
}
