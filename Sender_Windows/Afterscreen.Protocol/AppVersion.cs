namespace Afterscreen.Protocol;

/// <summary>Mac <c>AppVersion</c>: this app's version and release-tag order.</summary>
public static class AppVersion
{
    /// <summary>nil when unset (like <c>swift run</c> without a bundle version).</summary>
    public static string? Current { get; set; }

    /// <summary>Numbers of "v1.2.3" or "1.2"; null for any other shape.</summary>
    public static int[]? Parts(string text)
    {
        var bare = text.StartsWith('v') || text.StartsWith('V') ? text[1..] : text;
        var parts = bare.Split('.');
        if (parts.Length is < 1 or > 3) return null;
        var numbers = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            var p = parts[i];
            if (p.Length == 0) return null;
            foreach (var c in p)
                if (c is < '0' or > '9') return null;
            if (!int.TryParse(p, out var n)) return null; // overflow
            numbers[i] = n;
        }
        return numbers;
    }

    /// <summary>Missing parts count as 0: 1.1 equals 1.1.0.</summary>
    public static bool IsNewer(string candidate, string installed)
    {
        var a = Parts(candidate);
        var b = Parts(installed);
        if (a is null || b is null) return false;
        for (var i = 0; i < 3; i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
