using System.Globalization;

namespace Afterscreen.Sender.App;

/// <summary>Mac <c>L10n.t(en, ko)</c>: every string in the UI is written in both languages.</summary>
public static class L10n
{
    public static bool Korean { get; set; } = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko";

    public static string T(string en, string ko) => Korean ? ko : en;

    public const string UnavailableEn = "Not available on Windows yet";
    public const string UnavailableKo = "Windows에서는 아직 지원하지 않습니다";
    public static string Unavailable => T(UnavailableEn, UnavailableKo);
}
