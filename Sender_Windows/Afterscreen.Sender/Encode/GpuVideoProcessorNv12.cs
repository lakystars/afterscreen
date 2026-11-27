using Afterscreen.Sender.Capture;
using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Afterscreen.Sender.Encode;

/// <summary>
/// BGRA → NV12/P010 via <see cref="ID3D11VideoProcessor"/>.
/// Same D3D device as the source <see cref="GpuFrame"/> and the QSV DXGI manager — no CPU readback.
/// </summary>
internal sealed class GpuVideoProcessorNv12 : IDisposable
{
    private readonly ID3D11VideoDevice _videoDevice;
    private readonly ID3D11VideoContext _videoContext;
    private readonly ID3D11VideoProcessorEnumerator _enumerator;
    private readonly ID3D11VideoProcessor _processor;
    private readonly int _srcW, _srcH, _dstW, _dstH;
    private readonly bool _tenBit;
    private bool _disposed;

    public bool TenBit => _tenBit;

    private GpuVideoProcessorNv12(
        ID3D11VideoDevice videoDevice,
        ID3D11VideoContext videoContext,
        ID3D11VideoProcessorEnumerator enumerator,
        ID3D11VideoProcessor processor,
        int srcW, int srcH, int dstW, int dstH, bool tenBit)
    {
        _videoDevice = videoDevice;
        _videoContext = videoContext;
        _enumerator = enumerator;
        _processor = processor;
        _srcW = srcW;
        _srcH = srcH;
        _dstW = dstW;
        _dstH = dstH;
        _tenBit = tenBit;
    }

    public static GpuVideoProcessorNv12? TryCreate(
        D3dEncodeDevice device, int srcW, int srcH, int dstW, int dstH, bool tenBit)
    {
        if (srcW < 2 || srcH < 2 || dstW < 2 || dstH < 2) return null;
        ID3D11VideoDevice? vd = null;
        ID3D11VideoContext? vc = null;
        ID3D11VideoProcessorEnumerator? enumer = null;
        ID3D11VideoProcessor? proc = null;
        try
        {
            vd = device.Device.QueryInterface<ID3D11VideoDevice>();
            vc = device.Context.QueryInterface<ID3D11VideoContext>();
            var rate = new Rational(60, 1);
            var desc = new VideoProcessorContentDescription
            {
                InputFrameFormat = VideoFrameFormat.Progressive,
                InputFrameRate = rate,
                InputWidth = (uint)srcW,
                InputHeight = (uint)srcH,
                OutputFrameRate = rate,
                OutputWidth = (uint)dstW,
                OutputHeight = (uint)dstH,
                Usage = VideoUsage.PlaybackNormal,
            };
            vd.CreateVideoProcessorEnumerator(ref desc, out enumer).CheckError();
            var outFmt = tenBit ? Format.P010 : Format.NV12;
            enumer.CheckVideoProcessorFormat(Format.B8G8R8A8_UNorm, out var inSupport);
            enumer.CheckVideoProcessorFormat(outFmt, out var outSupport);
            if ((inSupport & VideoProcessorFormatSupport.Input) == 0
                || (outSupport & VideoProcessorFormatSupport.Output) == 0)
            {
                Console.WriteLine($"  [zerocopy] VP format unsupported in={inSupport} out={outSupport} fmt={outFmt}");
                return null;
            }

            vd.CreateVideoProcessor(enumer, 0, out proc).CheckError();
            vc.VideoProcessorSetStreamFrameFormat(proc, 0, VideoFrameFormat.Progressive);
            vc.VideoProcessorSetStreamSourceRect(proc, 0, true, new RawRect(0, 0, srcW, srcH));
            vc.VideoProcessorSetStreamDestRect(proc, 0, true, new RawRect(0, 0, dstW, dstH));
            vc.VideoProcessorSetOutputTargetRect(proc, true, new RawRect(0, 0, dstW, dstH));

            return new GpuVideoProcessorNv12(vd, vc, enumer, proc, srcW, srcH, dstW, dstH, tenBit);
        }
        catch (Exception ex)
        {
            Console.WriteLine("  [zerocopy] VideoProcessor unavailable: " + ex.Message);
            proc?.Dispose();
            enumer?.Dispose();
            vc?.Dispose();
            vd?.Dispose();
            return null;
        }
    }

    /// <summary>
    /// Create an NV12/P010 texture suitable as VP output and QSV DXGI input.
    /// Prefers BindFlags.None (VP-friendly on Iris); falls back to RT+SRV.
    /// </summary>
    public static ID3D11Texture2D CreateOutputTexture(ID3D11Device device, int w, int h, bool tenBit)
    {
        var fmt = tenBit ? Format.P010 : Format.NV12;
        var desc = new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = fmt,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            CPUAccessFlags = CpuAccessFlags.None,
            MiscFlags = ResourceOptionFlags.None,
        };
        Exception? last = null;
        // Iris VP output views often need RenderTarget; QSV DXGI accepts RT+SRV or bare.
        foreach (var bind in new[]
                 {
                     BindFlags.RenderTarget,
                     BindFlags.ShaderResource | BindFlags.RenderTarget,
                     BindFlags.None,
                 })
        {
            try
            {
                desc.BindFlags = bind;
                var tex = device.CreateTexture2D(desc);
                // Prove the VP can bind it before we keep it.
                return tex;
            }
            catch (Exception ex)
            {
                last = ex;
            }
        }
        throw last ?? new InvalidOperationException("VP output texture create failed");
    }

    /// <summary>Blit <paramref name="frame"/> into an NV12/P010 texture on the same device. Caller holds ContextLock.</summary>
    public void Convert(GpuFrame frame, ID3D11Texture2D destNv12)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (frame.Width != _srcW || frame.Height != _srcH)
            throw new ArgumentException($"frame size {frame.Width}x{frame.Height} != VP {_srcW}x{_srcH}");

        var inDesc = new VideoProcessorInputViewDescription
        {
            FourCC = 0,
            ViewDimension = VideoProcessorInputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
        };
        var hrIn = _videoDevice.CreateVideoProcessorInputView(frame.Texture, _enumerator, inDesc, out var inputView);
        if (hrIn.Failure)
            throw new InvalidOperationException($"CreateVideoProcessorInputView {hrIn}");
        using (inputView)
        {
            var outDesc = new VideoProcessorOutputViewDescription
            {
                ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
            };
            var hrOut = _videoDevice.CreateVideoProcessorOutputView(destNv12, _enumerator, outDesc, out var outputView);
            if (hrOut.Failure)
            {
                Format fmt;
                try { fmt = destNv12.Description.Format; }
                catch { fmt = Format.Unknown; }
                throw new InvalidOperationException(
                    $"CreateVideoProcessorOutputView {hrOut} fmt={fmt} bind={destNv12.Description.BindFlags}");
            }
            using (outputView)
            {
                var stream = new VideoProcessorStream
                {
                    Enable = true,
                    OutputIndex = 0,
                    InputFrameOrField = 0,
                    PastFrames = 0,
                    FutureFrames = 0,
                    InputSurface = inputView,
                };
                var hrBlt = _videoContext.VideoProcessorBlt(_processor, outputView, 0, 1, new[] { stream });
                if (hrBlt.Failure)
                    throw new InvalidOperationException($"VideoProcessorBlt {hrBlt}");
            }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _processor.Dispose();
        _enumerator.Dispose();
        _videoContext.Dispose();
        _videoDevice.Dispose();
    }
}
