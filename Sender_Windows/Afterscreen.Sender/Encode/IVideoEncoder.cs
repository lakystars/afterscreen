namespace Afterscreen.Sender.Encode;

/// <summary>Hybrid video layer. MF H.264/HEVC today; adapter chosen via DXGI, not vendor APIs.</summary>
public interface IVideoEncoder : IDisposable
{
    string BackendName { get; }
    bool IsHardware { get; }
    /// <summary>Mac outbox waitsForVideo — prior input not yet drained.</summary>
    bool InputInFlight { get; }
    EncodedVideoFrame? Encode(byte[] bgra, int width, int height, bool forceKeyframe);
    /// <summary>Drain only; used when the gate is held back by <see cref="InputInFlight"/>.</summary>
    EncodedVideoFrame? PollOutput(int budgetMs);
    /// <summary>Mac VideoEncoder.setBitrate: applies from the next frames; false when the encoder cannot change it.</summary>
    bool SetBitrate(int bitsPerSecond);
    /// <summary>0…100 quality knob (ICodecAPI CommonQuality); false when unsupported.</summary>
    bool SetQuality(int quality0To100);
}
