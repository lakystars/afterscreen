using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using NAudio.Wave;

namespace Afterscreen.Sender.Capture;

/// <summary>
/// Windows Application Loopback (process loopback): captures rendered audio independent of the
/// endpoint mute point — Mac <c>CATapDescription.muteBehavior = .mutedWhenTapped</c> analogue.
/// Exclude our PID so Afterscreen's own output is not fed back; then mute the speakers safely.
/// Requires Windows 10 build 20348+.
/// </summary>
internal sealed class ProcessLoopbackCapture : IDisposable
{
    const string VadProcessLoopback = @"VAD\Process_Loopback";
    static readonly Guid IidAudioClient = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    static readonly Guid IidCaptureClient = new("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

    readonly IAudioClient _client;
    readonly IProcessAudioCaptureClient _capture;
    readonly byte[] _record;
    readonly int _bytesPerFrame;
    Thread? _thread;
    volatile bool _run;
    bool _disposed;

    public WaveFormat WaveFormat { get; }
    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler? RecordingStopped;

    ProcessLoopbackCapture(IAudioClient client, IProcessAudioCaptureClient capture, WaveFormat format)
    {
        _client = client;
        _capture = capture;
        WaveFormat = format;
        _bytesPerFrame = format.Channels * format.BitsPerSample / 8;
        _record = new byte[Math.Max(4 * 1024, format.AverageBytesPerSecond / 5)];
    }

    /// <summary>Exclude <paramref name="excludePid"/> (and children) from the capture mix.</summary>
    public static ProcessLoopbackCapture? TryStart(uint excludePid)
    {
        try
        {
            var client = Activate(excludePid);
            var format = new WaveFormat(48000, 16, 2); // PCM — AutoConvert from engine
            var formatPtr = AllocPcm16Stereo48k();
            // AUDCLNT_STREAMFLAGS_LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY
            const int flags = unchecked((int)0x00020000) | unchecked((int)0x80000000) | 0x08000000;
            var session = Guid.Empty;
            int hr;
            try
            {
                hr = client.Initialize(0, flags, 100_000_0, 0, formatPtr, ref session);
            }
            finally { Marshal.FreeHGlobal(formatPtr); }
            if (hr != 0)
            {
                Marshal.ReleaseComObject(client);
                Marshal.ThrowExceptionForHR(hr);
            }
            var iid = IidCaptureClient;
            hr = client.GetService(ref iid, out var svc);
            if (hr != 0 || svc is null)
            {
                Marshal.ReleaseComObject(client);
                Marshal.ThrowExceptionForHR(hr != 0 ? hr : unchecked((int)0x80004005));
            }
            var capture = (IProcessAudioCaptureClient?)svc
                ?? throw Marshal.GetExceptionForHR(unchecked((int)0x80004005))!;
            return new ProcessLoopbackCapture(client, capture, format);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[audio] process-loopback unavailable: " + ex.Message);
            return null;
        }
    }

    public void StartRecording()
    {
        if (_thread is not null) return;
        _run = true;
        Marshal.ThrowExceptionForHR(_client.Start());
        _thread = new Thread(ReadLoop)
        {
            IsBackground = true,
            Name = "afterscreen-process-loopback",
            Priority = ThreadPriority.BelowNormal,
        };
        _thread.Start();
    }

    public void StopRecording()
    {
        _run = false;
        try { _thread?.Join(1000); } catch { /* ignore */ }
        _thread = null;
        try { _client.Stop(); } catch { /* ignore */ }
    }

    void ReadLoop()
    {
        try
        {
            while (_run)
            {
                Thread.Sleep(10);
                Marshal.ThrowExceptionForHR(_capture.GetNextPacketSize(out var packet));
                var offset = 0;
                while (packet > 0)
                {
                    Marshal.ThrowExceptionForHR(_capture.GetBuffer(out var ptr, out var frames, out var flags, out _, out _));
                    var bytes = frames * _bytesPerFrame;
                    if (bytes > 0)
                    {
                        if (offset + bytes > _record.Length)
                        {
                            if (offset > 0)
                                DataAvailable?.Invoke(this, new WaveInEventArgs(_record, offset));
                            offset = 0;
                        }
                        if ((flags & 2) == 0) // not Silent
                            Marshal.Copy(ptr, _record, offset, Math.Min(bytes, _record.Length - offset));
                        else
                            Array.Clear(_record, offset, Math.Min(bytes, _record.Length - offset));
                        offset += Math.Min(bytes, _record.Length - offset);
                    }
                    Marshal.ThrowExceptionForHR(_capture.ReleaseBuffer(frames));
                    Marshal.ThrowExceptionForHR(_capture.GetNextPacketSize(out packet));
                }
                if (offset > 0)
                    DataAvailable?.Invoke(this, new WaveInEventArgs(_record, offset));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("[audio] process-loopback read: " + ex.Message);
        }
        finally
        {
            RecordingStopped?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopRecording();
        Marshal.ReleaseComObject(_capture);
        Marshal.ReleaseComObject(_client);
    }

    static IntPtr AllocPcm16Stereo48k()
    {
        var p = Marshal.AllocHGlobal(18);
        Marshal.WriteInt16(p, 0, 1);             // WAVE_FORMAT_PCM
        Marshal.WriteInt16(p, 2, 2);             // channels
        Marshal.WriteInt32(p, 4, 48000);
        Marshal.WriteInt32(p, 8, 48000 * 4);     // avg bytes/sec
        Marshal.WriteInt16(p, 12, 4);            // block align
        Marshal.WriteInt16(p, 14, 16);           // bits
        Marshal.WriteInt16(p, 16, 0);            // cbSize
        return p;
    }

    static IAudioClient Activate(uint excludePid)
    {
        var activation = new ActivationParams
        {
            ActivationType = 1, // ProcessLoopback
            TargetProcessId = excludePid,
            ProcessLoopbackMode = 1, // ExcludeTargetProcessTree
        };
        var blobData = Marshal.AllocHGlobal(12);
        var propPtr = Marshal.AllocHGlobal(24);
        try
        {
            Marshal.StructureToPtr(activation, blobData, false);
            // PROPVARIANT VT_BLOB: vt@0, blob.Length@8, blob.Data@16 (x64)
            Marshal.WriteInt16(propPtr, 0, 0x0041);
            Marshal.WriteInt16(propPtr, 2, 0);
            Marshal.WriteInt16(propPtr, 4, 0);
            Marshal.WriteInt16(propPtr, 6, 0);
            Marshal.WriteInt32(propPtr, 8, 12);
            Marshal.WriteInt32(propPtr, 12, 0); // pad
            Marshal.WriteIntPtr(propPtr, 16, blobData);

            var handler = new CompletionHandler();
            var iid = IidAudioClient;
            ActivateAudioInterfaceAsync(VadProcessLoopback, ref iid, propPtr, handler, out _);
            if (!handler.Done.Wait(8000))
                throw new TimeoutException("ActivateAudioInterfaceAsync");
            if (handler.Hr != 0 || handler.Client is null)
                Marshal.ThrowExceptionForHR(handler.Hr != 0 ? handler.Hr : unchecked((int)0x80004005));
            return handler.Client!;
        }
        finally
        {
            Marshal.FreeHGlobal(propPtr);
            Marshal.FreeHGlobal(blobData);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ActivationParams
    {
        public int ActivationType;
        public uint TargetProcessId;
        public int ProcessLoopbackMode;
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity,
            IntPtr format, ref Guid sessionGuid);
        void GetBufferSize(out uint size);
        void GetStreamLatency(out long latency);
        void GetCurrentPadding(out int padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr deviceFormatPointer);
        void GetDevicePeriod(out long defaultDevicePeriod, out long minimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        void Reset();
        void SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService([In] ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object? interfacePointer);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IProcessAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr dataBuffer, out int numFramesToRead, out int bufferFlags, out long devicePosition, out long qpcPosition);
        [PreserveSig] int ReleaseBuffer(int numFramesRead);
        [PreserveSig] int GetNextPacketSize(out int numFramesInNextPacket);
    }

    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivateAudioInterfaceAsyncOperation
    {
        void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object? activatedInterface);
    }

    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivateAudioInterfaceCompletionHandler
    {
        void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
    }

    [ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAgileObject { }

    [ComVisible(true)]
    sealed class CompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public ManualResetEventSlim Done { get; } = new(false);
        public IAudioClient? Client;
        public int Hr;

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
        {
            try
            {
                activateOperation.GetActivateResult(out Hr, out var unk);
                if (Hr == 0 && unk is not null)
                    Client = (IAudioClient)unk;
            }
            catch (Exception ex)
            {
                Console.WriteLine("[audio] process-loopback activate: " + ex.Message);
                Hr = unchecked((int)0x80004005);
            }
            finally { Done.Set(); }
        }
    }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    static extern void ActivateAudioInterfaceAsync(
        [In, MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [In] ref Guid riid,
        [In] IntPtr activationParams,
        [In] IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);
}
