using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Afterscreen.Sender.App;

public sealed class ReceiverEntry
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 50206;
    public string Model { get; set; } = "";
    public string Panel { get; set; } = "";
    /// <summary>Bonjour TXT <c>id</c> / Welcome <c>receiverID</c> — lasting identity across renames and new ports.</summary>
    public string DeviceId { get; set; } = "";
    public string Address => $"{Host}:{Port}";
    /// <summary>Bonjour answers for it now (not stored).</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool Found { get; set; }
}

/// <summary>Mac <c>SenderSettings</c> (the parts that exist here), kept as JSON next to the pairing store.</summary>
public sealed class AppSettings
{
    public List<ReceiverEntry> Receivers { get; set; } = new();
    public string? LastReceiver { get; set; }
    /// <summary>Bonjour name of the last connected receiver (auto-connect target; address/port change on every restart).</summary>
    public string? LastReceiverName { get; set; }
    /// <summary>TXT <c>id</c> of the last receiver when known.</summary>
    public string? LastReceiverId { get; set; }
    /// <summary>Mac <c>autoConnect</c>: reconnect when a paired (or cable) receiver appears.</summary>
    public bool AutoConnect { get; set; } = true;
    /// <summary>Mac <c>checksUpdates</c>: poll GitHub releases (default on).</summary>
    public bool ChecksUpdates { get; set; } = true;
    /// <summary>Mac <c>endPower</c>: receiver after Disconnect / Quit (default keep on).</summary>
    public string EndPower { get; set; } = "keepOn"; // keepOn | sleep | shutDown
    /// <summary>"extend" (virtual/second monitor) or "mirror" (main). Mac default: extend.</summary>
    public string DisplayRole { get; set; } = "extend";
    /// <summary>Mac <c>link</c> pin: auto | ethernet | wifi (Thunderbolt/USB later).</summary>
    public string PreferredLink { get; set; } = "auto";
    /// <summary>Mac <c>streamResolution</c>: auto | panel | reduced (four fifths).</summary>
    public string StreamResolution { get; set; } = "auto";
    public bool MenuBarStats { get; set; } = true;
    public string Language { get; set; } = "auto";           // auto | en | ko
    /// <summary>Receiver smoothing level: 0 off, 1 weak, 2 normal (default), 3 strong.</summary>
    public int Deband { get; set; } = 2;
    /// <summary>Mac <c>brightnessFollows</c>: receiver tracks the PC panel (default on).</summary>
    public bool BrightnessFollows { get; set; } = true;
    /// <summary>Mac <c>receiverBrightness</c>: manual receiver level when not following.</summary>
    public double ReceiverBrightness { get; set; } = 0.5;
    /// <summary>Mac <c>brightnessOffsets</c>: stops (−1…1) by receiver TXT id.</summary>
    public Dictionary<string, double> BrightnessOffsets { get; set; } = new();
    public bool ShowConnection { get; set; }
    public bool ShowPicture { get; set; }
    public bool ShowResources { get; set; }
    public bool ShowHardware { get; set; }

    private static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AfterscreenSender");
    public static string StoreDir => Dir;
    private static string FilePath => Path.Combine(Dir, "app-settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch { /* corrupt file: start fresh */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* settings are a convenience */ }
    }
}
