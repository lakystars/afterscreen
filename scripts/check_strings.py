#!/usr/bin/env python3
"""Checks Localization/*.lproj tables against the L10n.s keys

Fails on: missing or unused keys, duplicates, non-literal keys,
placeholder types unlike the key's, a stray %,
and InfoPlist keys the build script does not write
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = "Afterscreen.strings"
# Placeholders L10n.s takes; any other % is stray
SPEC = re.compile(r"%(?:%|(?:(\d+)\$)?(@|lld|(?:\.\d+)?f))")
SWIFT_ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "'": "'"}


def arguments(text):
    """Placeholder type by position, and whether numbered

    ValueError on a stray % or broken numbering
    """
    found, styles, plain, i = {}, set(), 0, 0
    while (i := text.find("%", i)) >= 0:
        m = SPEC.match(text, i)
        if not m:
            raise ValueError(f"stray % at {i}: use %@, %lld, %f or %%")
        i = m.end()
        if m.group(0) == "%%":
            continue
        if m.group(1):
            position = int(m.group(1))
        else:
            plain += 1
            position = plain
        styles.add(bool(m.group(1)))
        if found.setdefault(position, m.group(2)) != m.group(2):
            raise ValueError(f"argument {position} has two types")
    if len(styles) > 1:
        raise ValueError("numbered and plain placeholders mixed")
    if sorted(found) != list(range(1, len(found) + 1)):
        raise ValueError(f"positions {sorted(found)} skip a number")
    return found, True in styles


def parse_strings(path):
    """Entries and duplicate keys of a .strings file

    ValueError names the line of a syntax error
    """
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
    """{key: (first use, formatted)} and problems of L10n.s calls

    The table is looked up by the key: one plain literal
    """
    keys, problems = {}, []
    call = re.compile(r'L10n\.s\(\s*"((?:[^"\\\n]|\\.)*)"\s*([,)])')
    for path in sorted(ROOT.glob("*/Sources/**/*.swift")):
        where = path.relative_to(ROOT)
        # Commented-out calls are no use; line numbers kept
        text = re.sub(r"(?m)^[ \t]*//.*$", "", path.read_text(encoding="utf-8"))
        for start in (m.start() for m in re.finditer(r"L10n\.s\(", text)):
            line = f"{where}:{text.count(chr(10), 0, start) + 1}"
            m = call.match(text, start)
            if not m:
                problems.append(f"{line}: L10n.s needs one plain string literal key")
            elif "\\(" in m.group(1):
                problems.append(f"{line}: L10n.s key has \\( interpolation; pass %@ arguments")
            else:
                key, formatted = unescape_swift(m.group(1)), m.group(2) == ","
                if keys.setdefault(key, (line, formatted))[1] != formatted:
                    problems.append(f"{line}: {key!r} is used with and without arguments")
    return keys, problems


def main():
    used, problems = used_keys()
    types = {}
    for key, (where, formatted) in used.items():
        if not formatted:
            if SPEC.search(key):
                problems.append(f"{where}: {key!r} has a placeholder or %% but no arguments")
            continue
        try:
            types[key] = arguments(key)[0]
        except ValueError as e:
            problems.append(f"{where}: {key!r}: {e}")
    lprojs = sorted((ROOT / "Localization").glob("*.lproj"))
    if not lprojs:
        problems.append("Localization/: no .lproj folder")
    for lproj in lprojs:
        name = f"{lproj.name}/{TABLE}"
        try:
            entries, duplicates = parse_strings(lproj / TABLE)
        except (OSError, ValueError) as e:
            problems.append(str(e))
            continue
        problems += [f"{name}: duplicate key {k!r}" for k in duplicates]
        problems += [f"{name}: missing {k!r} (used at {where})" for k, (where, _) in used.items() if k not in entries]
        problems += [f"{name}: unused {k!r}" for k in entries if k not in used]
        for key, value in entries.items():
            if key not in used:
                continue
            if not used[key][1]:
                if SPEC.search(value):
                    problems.append(f"{name}: {key!r} takes no arguments; its value has a placeholder or %%")
                continue
            if key not in types:
                continue
            try:
                found, numbered = arguments(value)
            except ValueError as e:
                problems.append(f"{name}: {key!r}: {e}")
                continue
            if found != types[key]:
                problems.append(f"{name}: placeholder types differ for {key!r}: {types[key]} vs {found}")
            elif len(found) > 1 and not numbered:
                problems.append(f"{name}: {key!r} has {len(found)} arguments; number them (%1$@)")
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
