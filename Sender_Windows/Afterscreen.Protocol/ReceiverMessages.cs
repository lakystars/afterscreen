using System.Text.Json.Serialization;

namespace Afterscreen.Protocol;

/// <summary>Mac <c>ReceiverStats</c>: what the receiver measures, once a second (message Stats).</summary>
public sealed class ReceiverStats
{
    [JsonPropertyName("receivedFPS")] public double ReceivedFPS { get; set; }
    [JsonPropertyName("displayedFPS")] public double DisplayedFPS { get; set; }
    public double UploadMs { get; set; }
    public double DecompressMs { get; set; }
    public int LateFrames { get; set; }
    public double CpuPercent { get; set; }
    public ulong MemoryBytes { get; set; }
    public double GpuPercent { get; set; }
    public double? AudioBufferMs { get; set; }
    public int? AudioUnderruns { get; set; }
    public double? PanelLevel { get; set; }
    public bool? Shown { get; set; }
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ReceiverPresentation { space, cover }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ReceiverEffect { tiles, none }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ReceiverOnDisconnect { showDesktop, sleepDisplay }

/// <summary>Mac <c>ReceiverOptions</c>: the connected receiver's own settings, as it allows (message ReceiverOptions).</summary>
public sealed class ReceiverOptions
{
    public sealed class ScreenInfo
    {
        public string Key { get; set; } = "";
        public string Name { get; set; } = "";
        public PixelSize Pixels { get; set; } = new();
    }

    /// <summary>false: no proven key or cable, edits are ignored.</summary>
    public bool Editable { get; set; }
    public bool Hud { get; set; }
    public ReceiverPresentation Presentation { get; set; }
    public List<ScreenInfo> Screens { get; set; } = new();
    /// <summary>The chosen screen's key; null = automatic.</summary>
    public string? Screen { get; set; }
    public string? MissingScreen { get; set; }
    public bool MatchPanelMode { get; set; }
    public ReceiverEffect Effect { get; set; }
    public ReceiverOnDisconnect OnDisconnect { get; set; }
    public bool LaunchAtLogin { get; set; }

    /// <summary>As the receiver will report it after <paramref name="change"/> (Mac <c>applying</c>).</summary>
    public ReceiverOptions Applying(ReceiverOptionsChange change)
    {
        var next = (ReceiverOptions)MemberwiseClone();
        if (change.Hud is { } hud) next.Hud = hud;
        if (change.Presentation is { } p) next.Presentation = p;
        if (change.Screen is { } key)
        {
            if (key.Length == 0) { next.Screen = null; next.MissingScreen = null; }
            else if (Screens.Any(s => s.Key == key)) { next.Screen = key; next.MissingScreen = null; }
        }
        if (change.MatchPanelMode is { } m) next.MatchPanelMode = m;
        if (change.Effect is { } e) next.Effect = e;
        if (change.OnDisconnect is { } d) next.OnDisconnect = d;
        if (change.LaunchAtLogin is { } l) next.LaunchAtLogin = l;
        return next;
    }
}

/// <summary>Mac <c>ReceiverOptionsChange</c>: an edit; null fields stay as they are (message SetReceiverOptions).</summary>
public sealed class ReceiverOptionsChange
{
    public bool? Hud { get; set; }
    public ReceiverPresentation? Presentation { get; set; }
    /// <summary>A listed screen's key; empty for automatic.</summary>
    public string? Screen { get; set; }
    public bool? MatchPanelMode { get; set; }
    public ReceiverEffect? Effect { get; set; }
    public ReceiverOnDisconnect? OnDisconnect { get; set; }
    public bool? LaunchAtLogin { get; set; }
}

/// <summary>Receiver 8-bit step smoothing level (message Deband: one byte).</summary>
public enum Deband : byte { Off = 0, Weak = 1, Normal = 2, Strong = 3 }
