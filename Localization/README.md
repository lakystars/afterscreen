# Localization

UI text lives in `<code>.lproj/Localizable.strings`; the English text is the key.
English needs no file: a missing key shows the key.

```swift
L10n.s("Remove")                       // plain
L10n.s("%@ settings", receiver)        // %@ String, %lld Int
```

1. Write the call with `L10n.s`, the English text with placeholders as the key.
2. Add the key to every `<code>.lproj/Localizable.strings`.
3. `python3 scripts/check_strings.py` — missing, unused and mismatched placeholders fail it.

`InfoPlist.strings` translates the privacy prompts. `scripts/build_apps.sh` compiles both
into each app's `Contents/Resources/<code>.lproj`.

`L10n.t(english, korean)` still works and is being moved over file by file.
Running with `swift run` has no app bundle, so it shows English only.
