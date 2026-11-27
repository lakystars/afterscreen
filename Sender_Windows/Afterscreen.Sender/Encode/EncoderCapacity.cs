using System.Text.Json;
using Afterscreen.Protocol;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// Mac <c>EncoderCapacity</c>: frames per second this machine's hardware encoder sustains per layer size, measured once per
/// size (codec, bit depth, size) and kept while the process runs. Pipelined like the stream, every frame changed in full;
/// a slower machine then takes a smaller video layer. Low results are measured again after <see cref="RetrySeconds"/>
/// (a busy encoder reads short).
/// <para>
/// QSV/MF encoder create+dispose leaves ~300 MB of driver memory in the process working set (known). Results are also
/// cached under LocalAppData so App restarts do not remasure and stack that residue.
/// </para>
/// </summary>
public static class EncoderCapacity
{
    private static readonly Dictionary<string, (double Fps, long At)> Measured = new();
    private static readonly object Lock = new();
    private static bool _diskLoaded;

    /// <summary>Timed frames, about half a second at 60 fps.</summary>
    public const int Frames = 30;
    /// <summary>Not timed: first keyframe, encoder warming up.</summary>
    public const int Warmup = 3;
    /// <summary>
    /// Share of the stream's rate the encoder must reach with every frame changing in full. The Mac asks for 1.05x. Here the default is
    /// 0.7x on purpose (the user wants the 2560x1440 motion layer kept): the Iris Xe reads 45-66 fps of worst-case 10-bit 1440p and 33 fps
    /// at 4K, so 0.7x keeps 1440p and still drops to 1080p on a clearly weaker encoder, while 1.05x would put it on 1080p.
    /// AFTERSCREEN_CAPACITY_MARGIN=1.05 restores the Mac value, AFTERSCREEN_CAPACITY=0 skips the measurement.
    /// </summary>
    public static double Margin { get; } =
        double.TryParse(Environment.GetEnvironmentVariable("AFTERSCREEN_CAPACITY_MARGIN"), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var m) && m is >= 0.3 and <= 2 ? m : 0.7;
    public const double RetrySeconds = 600;
    /// <summary>Disk cache lifetime — remasure after this so a driver update can change the answer.</summary>
    public const double DiskCacheDays = 30;

    /// <summary>Layer sizes the bitrate fills at the Mac's minimum 0.15 bits per pixel per frame, largest first, up to <paramref name="max"/>.</summary>
    public static IReadOnlyList<PixelSize> VideoBoxes(int bitrate, VideoCodec codec, double fps, PixelSize max)
    {
        // Mac PathPolicy.videoSizes; H.264 skips 4K. Windows caps the layer at <paramref name="max"/> (see EncodeServices.VideoMax).
        var all = new List<PixelSize> { new(3840, 2160), new(2560, 1440), new(1920, 1080) };
        if (codec != VideoCodec.hevc)
        {
            all.RemoveAt(0);                      // H.264 stops at 1440p (level 5.1)
            if ((long)max.Width * max.Height > 2560L * 1440) max = new PixelSize(2560, 1440);
        }
        all = all.Where(s => (long)s.Width * s.Height <= (long)max.Width * max.Height).ToList();
        // A cap that is not one of the Mac's boxes (the stream's own size, e.g. 2880x1620) is itself the largest box, measured at that size
        if (all.Count == 0 || (all[0].Width != max.Width || all[0].Height != max.Height) && (long)all[0].Width * all[0].Height < (long)max.Width * max.Height)
            all.Insert(0, max);
        var first = all.FindIndex(s => bitrate / Math.Max(1.0, fps) / ((double)s.Width * s.Height) >= 0.15);
        if (first < 0) first = all.Count - 1;
        return all.Skip(first).ToList();
    }

    /// <summary>First of <paramref name="sizes"/> (largest first) kept up at <paramref name="fps"/>; the smallest when none is. Blocks while measuring.</summary>
    public static PixelSize Largest(IReadOnlyList<PixelSize> sizes, VideoCodec codec, bool tenBit, int bitrate, double fps,
        GpuAdapterInfo? adapter, D3dEncodeDevice? d3d)
    {
        if (sizes.Count == 1 || Environment.GetEnvironmentVariable("AFTERSCREEN_CAPACITY") == "0") return sizes[0];
        foreach (var size in sizes)
            if (FramesPerSecond(size, codec, tenBit, bitrate, fps, adapter, d3d) >= fps * Margin)
                return size;
        return sizes[^1];
    }

    public static double FramesPerSecond(PixelSize size, VideoCodec codec, bool tenBit, int bitrate, double wanted,
        GpuAdapterInfo? adapter, D3dEncodeDevice? d3d)
    {
        var key = $"{codec}{(tenBit ? "10" : "8")}-{size.Width}x{size.Height}";
        var now = Environment.TickCount64;
        EnsureDiskLoaded();
        lock (Lock)
        {
            if (Measured.TryGetValue(key, out var kept) && (kept.Fps >= wanted * Margin || now - kept.At < RetrySeconds * 1000))
                return kept.Fps;
        }
        var fps = Measure(size, codec, tenBit, bitrate, wanted, adapter, d3d);
        // Remasure only on hard failure (0). A second create+dispose costs ~300 MB of QSV driver
        // residue in the working set; a merely noisy low reading is not worth that.
        if (fps <= 0)
        {
            var again = Measure(size, codec, tenBit, bitrate, wanted, adapter, d3d);
            Console.WriteLine($"[capacity] {key}: first measure failed, tried again: {again:0.0} fps");
            fps = again;
        }
        else if (fps < wanted * Margin)
            Console.WriteLine($"[capacity] {key}: {fps:0.0} fps under bar (wanted {wanted:0} x {Margin:0.00}); not remasuring (QSV dispose residue)");
        lock (Lock) Measured[key] = (fps, now);
        SaveDisk(key, fps);
        Console.WriteLine($"[capacity] {key}: encoder sustains {fps:0.0} fps (wanted {wanted:0} x {Margin:0.00})");
        return fps;
    }

    private static double Measure(PixelSize size, VideoCodec codec, bool tenBit, int bitrate, double wanted,
        GpuAdapterInfo? adapter, D3dEncodeDevice? d3d)
    {
        var layer = new VideoLayer { Codec = codec, Pixels = size, Bitrate = bitrate, TenBit = tenBit };
        try
        {
            using var encoder = MfH264Encoder.TryCreate(layer, wanted, adapter, d3d);
            if (encoder is null || !encoder.IsHardware) return 0;
            return encoder.Benchmark(Frames, Warmup);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[capacity] measure failed: " + ex.Message);
            return 0;
        }
    }

    private static string CachePath()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Afterscreen");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, "encoder-capacity.json");
    }

    private static void EnsureDiskLoaded()
    {
        lock (Lock)
        {
            if (_diskLoaded) return;
            _diskLoaded = true;
            try
            {
                var path = CachePath();
                if (!File.Exists(path)) return;
                var json = File.ReadAllText(path);
                var entries = JsonSerializer.Deserialize<Dictionary<string, DiskEntry>>(json);
                if (entries is null) return;
                var now = DateTimeOffset.UtcNow;
                foreach (var (key, e) in entries)
                {
                    if ((now - e.At).TotalDays > DiskCacheDays) continue;
                    Measured[key] = (e.Fps, Environment.TickCount64);
                }
                if (Measured.Count > 0)
                    Console.WriteLine($"[capacity] loaded {Measured.Count} cached size(s) from disk");
            }
            catch (Exception ex)
            {
                Console.WriteLine("[capacity] cache load: " + ex.Message);
            }
        }
    }

    private static void SaveDisk(string key, double fps)
    {
        try
        {
            Dictionary<string, DiskEntry> entries;
            var path = CachePath();
            if (File.Exists(path))
            {
                entries = JsonSerializer.Deserialize<Dictionary<string, DiskEntry>>(File.ReadAllText(path))
                          ?? new Dictionary<string, DiskEntry>();
            }
            else
                entries = new Dictionary<string, DiskEntry>();
            entries[key] = new DiskEntry { Fps = fps, At = DateTimeOffset.UtcNow };
            File.WriteAllText(path, JsonSerializer.Serialize(entries));
        }
        catch (Exception ex)
        {
            Console.WriteLine("[capacity] cache save: " + ex.Message);
        }
    }

    private sealed class DiskEntry
    {
        public double Fps { get; set; }
        public DateTimeOffset At { get; set; }
    }
}
