using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Afterscreen.Sender.Encode;

/// <summary>Optional ICodecAPI tweaks (GOP / CBR / low-latency). Safe no-op when unsupported.</summary>
internal static class CodecApi
{
    private static readonly Guid RateControlMode = new("1c0608e9-370c-4710-8a58-cb518e98f5a2");
    private static readonly Guid MeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    private static readonly Guid GopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    private static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    private static readonly Guid ForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
    private static readonly Guid MfLowLatency = new("fe87c62a-70a5-11e0-b3f3-c60c1fea119e");
    /// <summary>CODECAPI_AVEncVideoEncodeQP — constant QP when RateControlMode is not CBR.</summary>
    private static readonly Guid EncodeQp = new("2e006618-e146-4d5c-8a48-36b89b26a8fc");
    /// <summary>CODECAPI_AVEncCommonQuality — 0…100 quality knob on some MFTs.</summary>
    private static readonly Guid CommonQuality = new("fcbf57a3-7ea5-4b0c-9644-69b036c2c1e0");

    [ComImport]
    [Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICodecAPI
    {
        [PreserveSig] int IsSupported(ref Guid api);
        [PreserveSig] int IsModifiable(ref Guid api);
        [PreserveSig] int GetParameterRange(ref Guid api, out object valueMin, out object valueMax, out object steppingDelta);
        [PreserveSig] int GetParameterValues(ref Guid api, out IntPtr values, out uint valuesCount);
        [PreserveSig] int GetDefaultValue(ref Guid api, out object value);
        [PreserveSig] int GetValue(ref Guid api, out object value);
        [PreserveSig] int SetValue(ref Guid api, ref object value);
    }

    public static void ApplyLowLatency(IMFTransform transform, int bitrate)
    {
        try { transform.Attributes.Set(MfLowLatency, true); }
        catch { /* optional */ }

        try { transform.Attributes.Set(TransformAttributeKeys.TransformAsyncUnlock, true); }
        catch { /* optional */ }

        WithCodec(transform, codec =>
        {
            // ICodecAPI properties are VT_UI4 — a boxed int (VT_I4) is rejected by Intel QSV with
            // E_INVALIDARG, which the old code swallowed: GOP size and ForceKeyFrame never applied.
            Set(codec, "RateControlMode", RateControlMode, 1u);
            Set(codec, "MeanBitRate", MeanBitRate, (uint)bitrate);
            // Mac: MaxKeyFrameInterval = Int32.max - no periodic IDR (TCP is lossless); the receiver asks for a keyframe
            // (KeyRequest) and ForceKeyFrame answers it. (A 15-frame GOP here was a workaround for ForceKeyFrame not
            // working, which was a wrong GUID.)
            Set(codec, "GopSize", GopSize, 0x7FFFFFFFu);
            Set(codec, "LowLatency", LowLatency, true);
        });
    }

    /// <summary>Changes the target bitrate of a running encoder (CODECAPI_AVEncCommonMeanBitRate); false when it refuses.</summary>
    public static bool SetBitrate(IMFTransform transform, int bitsPerSecond)
    {
        var ok = false;
        WithCodec(transform, codec =>
        {
            var api = MeanBitRate;
            object value = (uint)bitsPerSecond;
            int hr;
            try { hr = codec.SetValue(ref api, ref value); }
            catch (Exception ex) { hr = ex.HResult; }
            ok = hr >= 0;
        });
        return ok;
    }

    /// <summary>Ask the MFT for an IDR on the next encoded sample (CODECAPI_AVEncVideoForceKeyFrame).</summary>
    public static void RequestKeyframe(IMFTransform transform) =>
        WithCodec(transform, codec => Set(codec, "ForceKeyFrame", ForceKeyFrame, 1u));

    /// <summary>Try constant QP (lower = higher quality). False when the MFT rejects it.</summary>
    public static bool SetEncodeQp(IMFTransform transform, uint qp)
    {
        var ok = false;
        WithCodec(transform, codec =>
        {
            var api = EncodeQp;
            object value = qp;
            int hr;
            try { hr = codec.SetValue(ref api, ref value); }
            catch (Exception ex) { hr = ex.HResult; }
            ok = hr >= 0;
            if (Verbose) Console.Error.WriteLine($"[codecapi] EncodeQP={qp} hr=0x{hr:X8}");
        });
        return ok;
    }

    /// <summary>Try 0…100 quality. False when unsupported.</summary>
    public static bool SetQuality(IMFTransform transform, uint quality0To100)
    {
        var ok = false;
        WithCodec(transform, codec =>
        {
            var api = CommonQuality;
            object value = Math.Clamp(quality0To100, 0u, 100u);
            int hr;
            try { hr = codec.SetValue(ref api, ref value); }
            catch (Exception ex) { hr = ex.HResult; }
            ok = hr >= 0;
            if (Verbose) Console.Error.WriteLine($"[codecapi] Quality={value} hr=0x{hr:X8}");
        });
        return ok;
    }

    private static void WithCodec(IMFTransform transform, Action<ICodecAPI> action)
    {
        var iid = typeof(ICodecAPI).GUID;
        var qi = Marshal.QueryInterface(transform.NativePointer, ref iid, out var codecPtr);
        if (qi != 0 || codecPtr == IntPtr.Zero)
        {
            if (Reported.Add("qi"))
                Console.Error.WriteLine($"[codecapi] QueryInterface(ICodecAPI) on the MFT failed 0x{qi:X8} — settings not applied");
            return;
        }
        try { action((ICodecAPI)Marshal.GetObjectForIUnknown(codecPtr)); }
        finally { Marshal.Release(codecPtr); }
    }

    private static readonly HashSet<string> Reported = new();
    private static readonly bool Verbose =
        string.Equals(Environment.GetEnvironmentVariable("AFTERSCREEN_MF_VERBOSE"), "1", StringComparison.Ordinal);

    private static void Set(ICodecAPI codec, string name, Guid api, object value)
    {
        int hr;
        try { hr = codec.SetValue(ref api, ref value); }
        catch (Exception ex) { hr = ex.HResult; }
        // Report each distinct failure once (ForceKeyFrame is called repeatedly).
        if (hr < 0 && Reported.Add($"{name}:{hr:X8}"))
            Console.Error.WriteLine($"[codecapi] {name} = {value} ({value.GetType().Name}) failed 0x{hr:X8}");
        if (Verbose && Reported.Add($"{name}:probe"))
        {
            var sup = codec.IsSupported(ref api);
            var mod = codec.IsModifiable(ref api);
            object? back = null;
            var g = codec.GetValue(ref api, out back);
            Console.Error.WriteLine(
                $"[codecapi] {name}: set={value} hr=0x{hr:X8} supported=0x{sup:X8} modifiable=0x{mod:X8} " +
                $"get=0x{g:X8} value={back ?? "n/a"}");
        }
    }
}
