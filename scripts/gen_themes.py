#!/usr/bin/env python3
"""Generate macterm's NvChadThemes.swift from NvChad/base46 theme sources.

Reads every lua/base46/themes/<slug>.lua and extracts:
  - base_16 palette (base00..base0F)
  - type ("dark"/"light")
  - UI accent (base_30.blue, falling back to base16 base0D)

Values may be literal hex strings (any Lua quote style), references into the
theme's own base_30 table ("M.base_30.red", bare "red"), other base16 keys,
or file-local "local name = '#hex'" bindings (e.g. slatewave.lua).

Terminal ANSI mapping is NvChad's own (lua/base46/term.lua):
  slots 0..15 = 01 08 0B 0A 0D 0E 0C 05 03 08 0B 0A 0D 0E 0C 07
so we only need to store the raw base16 values.
"""
import re
import pathlib

THEMES_DIR = pathlib.Path("/tmp/base46/lua/base46/themes")
OUT = pathlib.Path("/Users/zdenkovasic/Documents/CODING/macterm/macterm/Model/NvChadThemes.swift")

HEXVAL = r"['\"](#[0-9a-fA-F]{6})['\"]"

# Conventional display names for well-known themes; others are prettified generically.
PRETTY = {
    "onedark": "One Dark", "one_light": "One Light", "tokyonight": "Tokyo Night",
    "catppuccin": "Catppuccin Mocha", "gruvbox": "Gruvbox Dark",
    "everforest": "Everforest Dark", "nightowl": "Night Owl", "nord": "Nord",
    "kanagawa": "Kanagawa", "dracula": "Chadracula", "jellybeans": "Jellybeans",
    "monokai": "Monokai", "nightlamp": "Night Lamp", "rosepine": "Rosé Pine",
    "github_dark": "GitHub Dark", "github_light": "GitHub Light",
    "material-darker": "Material Darker", "material-deep-ocean": "Material Deep Ocean",
    "material-lighter": "Material Lighter", "default-dark": "Default Dark",
    "default-light": "Default Light",
}


def prettify(slug: str) -> str:
    if slug in PRETTY:
        return PRETTY[slug]
    words = re.split(r"[-_]", slug)
    return " ".join(w[:1].upper() + w[1:] for w in words if w)


def parse(path: pathlib.Path):
    src = path.read_text()

    def block(name: str) -> str:
        m = re.search(rf"M\.{name}\s*=\s*\{{(.*?)\n\}}", src, re.S)
        if not m:
            raise ValueError(f"{path.name}: no {name}")
        return m.group(1)

    # Named colors first: base_16 entries often reference them symbolically.
    named = {}
    for k, v in re.findall(rf"(\w+)\s*=\s*{HEXVAL}", block("base_30")):
        named[k] = v.lower()
    # File-local bindings (slatewave.lua: local slate_700 = '#334155').
    for n, h in re.findall(rf"local\s+(\w+)\s*=\s*{HEXVAL}", src):
        named.setdefault(n, h.lower())

    def resolved(val: str) -> str | None:
        v = val.strip()
        m = re.fullmatch(HEXVAL, v)
        if m:
            return m.group(1).lower()
        m = re.fullmatch(r"M\.base_30\.(\w+)|(\w+)", v)
        if not m:
            return None
        return named.get(m.group(1) or m.group(2))

    pairs = []
    for key, val in re.findall(r"(base[0-9A-F]{2})\s*=\s*([^\n,]+)[,\n]", block("base_16")):
        r = resolved(val)
        if r is None:
            # Last resort: another base16 entry by name.
            hit = next((v for k, v in pairs if k == val.strip()), None)
            if hit is None:
                raise ValueError(f"{path.name}: unparsable base_16 {key} = {val.strip()}")
            pairs.append((key, hit))
        else:
            pairs.append((key, r))

    palette = dict(pairs)
    if len(palette) != 16:
        raise ValueError(f"{path.name}: base_16 has {len(palette)} entries")
    base16 = [palette[f"base{n:02X}"] for n in range(0x10)]

    typ = re.search(r'M\.type\s*=\s*"(dark|light)"', src)
    if not typ:
        raise ValueError(f"{path.name}: no type")
    accent = named.get("blue") or base16[0x0D]
    return base16, typ.group(1) == "dark", accent


def main():
    rows = []
    for f in sorted(THEMES_DIR.glob("*.lua")):
        slug = f.stem
        base16, dark, accent = parse(f)
        rows.append((slug, prettify(slug), dark, accent, base16))
    rows.sort(key=lambda r: r[1].lower())

    lines = [
        "// GENERATED from NvChad/base46 (https://github.com/NvChad/base46, GPL-3.0)",
        "// source dir lua/base46/themes — regenerate with scripts/gen_themes.py, do not hand-edit.",
        "",
        "enum NvChadThemes {",
        "    /// (base46 slug, display name, isDark, UI accent, base00…base0F hex values)",
        "    static let raw: [(slug: String, name: String, dark: Bool, accent: String, base16: [String])] = [",
    ]
    for slug, name, dark, accent, base16 in rows:
        pal = ", ".join(f'"{c}"' for c in base16)
        esc = name.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(
            f'        ("{slug}", "{esc}", {"true" if dark else "false"}, "{accent}", [{pal}]),'
        )
    lines += ["    ]", "}"]

    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT} ({len(rows)} themes)")


if __name__ == "__main__":
    main()
