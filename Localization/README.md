# Localization

UI text lives in `<code>.lproj/Afterscreen.strings`; the English text is the key.
English needs no file: a missing key shows the key.
The table is not `Localizable.strings`: SwiftUI `Text` literals read that one in the system language.

```swift
L10n.s("Remove")                       // no arguments: shown as written
L10n.s("%@ settings", receiver)        // %@ String, %lld Int, %f Double
L10n.s("%lld%% sent", percent)         // with arguments, %% for %
```

1. Write the call with `L10n.s`. The key is one plain string literal, without `\(...)`.
2. Add the key to every `<code>.lproj/Afterscreen.strings`. Number two or more placeholders (`%1$@`).
3. `python3 scripts/check_strings.py` checks keys and placeholder types. `scripts/build_apps.sh` runs it first.

`InfoPlist.strings` translates the privacy prompts. `scripts/build_apps.sh` compiles both
into each app's `Contents/Resources/<code>.lproj`.

`L10n.t(english, korean)` still works. `t`, `s` and `L10n.shown` pick the same language.
`swift run` has no app bundle, so `L10n.s` text stays English.
