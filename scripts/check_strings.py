#!/usr/bin/env python3
"""Checks Localization/*.lproj/Localizable.strings against the L10n.s keys in the sources.

Fails on: a key used but missing, a key unused, a duplicate, a placeholder that does not
match the key's, an InfoPlist key the build script does not write.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@diouxXeEfgGcCsSp%])")
SWIFT_ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "'": "'"}


def placeholders(text):
    """Sorted (length, conversion) per argument; %% is no argument."""
    found = [(m.group(2) or "", m.group(3)) for m in PLACEHOLDER.finditer(text) if m.group(3) != "%"]
    return sorted(found)


def positions(text):
    return [int(m.group(1)) for m in PLACEHOLDER.finditer(text) if m.group(1)]


def parse_strings(path):
    """{key: value} of a .strings file; comments allowed; raises ValueError with the line."""
    text = path.read_text(encoding="utf-8")
    entries, duplicates, i, n = {}, [], 0, len(text)

    def line():
        return text.count("\n", 0, i) + 1

    def skip():
        nonlocal i
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end < 0:
                    raise ValueError(f"{path.name}:{line()}: unterminated comment")
                i = end + 2
            elif text.startswith("//", i):
                end = text.find("\n", i)
                i = n if end < 0 else end
            else:
                break

    def string():
        nonlocal i
        if i >= n or text[i] != '"':
            raise ValueError(f"{path.name}:{line()}: expected a quoted string")
        i += 1
        out = []
        while i < n and text[i] != '"':
            if text[i] == "\\":
                i += 1
                out.append(SWIFT_ESCAPES.get(text[i], "\\" + text[i]) if i < n else "")
            else:
                out.append(text[i])
            i += 1
        if i >= n:
            raise ValueError(f"{path.name}:{line()}: unterminated string")
        i += 1
        return "".join(out)

    while True:
        skip()
        if i >= n:
            return entries, duplicates
        key = string()
        skip()
        if text[i:i + 1] != "=":
            raise ValueError(f"{path.name}:{line()}: expected =")
        i += 1
        skip()
        value = string()
        skip()
        if text[i:i + 1] != ";":
            raise ValueError(f"{path.name}:{line()}: expected ;")
        i += 1
        if key in entries:
            duplicates.append(key)
        entries[key] = value


def unescape_swift(literal):
    out, i = [], 0
    while i < len(literal):
        if literal[i] == "\\":
            i += 1
            out.append(SWIFT_ESCAPES.get(literal[i], "\\" + literal[i]))
        else:
            out.append(literal[i])
        i += 1
    return "".join(out)


def used_keys():
    keys = {}
    call = re.compile(r'L10n\.s\(\s*"((?:[^"\\]|\\.)*)"')
    for path in ROOT.glob("*/Sources/**/*.swift"):
        for m in call.finditer(path.read_text(encoding="utf-8")):
            keys.setdefault(unescape_swift(m.group(1)), f"{path.relative_to(ROOT)}")
    return keys


def main():
    problems = []
    used = used_keys()
    lprojs = sorted((ROOT / "Localization").glob("*.lproj"))
    if not lprojs:
        problems.append("Localization/: no .lproj folder")
    for lproj in lprojs:
        table = lproj / "Localizable.strings"
        try:
            entries, duplicates = parse_strings(table)
        except (OSError, ValueError) as e:
            problems.append(str(e))
            continue
        name = f"{lproj.name}/Localizable.strings"
        problems += [f"{name}: duplicate key {k!r}" for k in duplicates]
        problems += [f"{name}: missing {k!r} (used in {where})" for k, where in used.items() if k not in entries]
        problems += [f"{name}: unused {k!r}" for k in entries if k not in used]
        for key, value in entries.items():
            if key not in used:
                continue
            if placeholders(key) != placeholders(value):
                problems.append(f"{name}: placeholders differ for {key!r}: {placeholders(key)} vs {placeholders(value)}")
            count = len(placeholders(key))
            numbered = positions(value)
            if numbered and (sorted(numbered) != list(range(1, count + 1))):
                problems.append(f"{name}: positions {numbered} do not number the {count} arguments of {key!r}")
            if count > 1 and not numbered:
                problems.append(f"{name}: {key!r} has {count} arguments; number them (%1$@)")
            if "%%" in key:
                problems.append(f"{name}: {key!r} has %%; a call without arguments is not formatted")
        info = lproj / "InfoPlist.strings"
        if info.exists():
            try:
                plist_keys, plist_dups = parse_strings(info)
            except (OSError, ValueError) as e:
                problems.append(str(e))
                continue
            build = (ROOT / "scripts" / "build_apps.sh").read_text(encoding="utf-8")
            problems += [f"{lproj.name}/InfoPlist.strings: duplicate key {k!r}" for k in plist_dups]
            problems += [f"{lproj.name}/InfoPlist.strings: {k} is not in build_apps.sh" for k in plist_keys if f"<key>{k}</key>" not in build]
    for p in problems:
        print(p, file=sys.stderr)
    print(f"{len(used)} keys used, {len(lprojs)} language(s), {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
