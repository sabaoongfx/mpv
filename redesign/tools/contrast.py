#!/usr/bin/env python3
"""WCAG 2.x contrast check for the juxtopposed palette (phase 5, colour side).

Reads the colours from redesign/bundle/osc.conf and the fixed Home/menu colours from
redesign/bundle/scripts/*.lua, then prints the contrast of every text and icon pair against its
background. Text needs 4.5:1 (WCAG 1.4.3); icons and component edges need 3:1 (WCAG 1.4.11).

This checks colours only. The screenshot check (control positions, real rendering) is in
redesign/PLAN.md and is run when asked.

Usage: python3 redesign/tools/contrast.py
"""
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OSC_CONF = os.path.join(ROOT, "redesign", "bundle", "osc.conf")
SCRIPTS = os.path.join(ROOT, "redesign", "bundle", "scripts")


def lum(hex6):
    def chan(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex6[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def osc_colours():
    out = {}
    with open(OSC_CONF, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*([a-z_A-Z]+)\s*=\s*#([0-9A-Fa-f]{6})\s*$", line)
            if m:
                out[m.group(1)] = m.group(2).upper()
    return out


def script_colours(name):
    """Named COL_* constants of one Lua script (ASS-style hex, same digits as RGB here)."""
    with open(os.path.join(SCRIPTS, name), encoding="utf-8") as f:
        src = f.read()
    vals = {}
    for m in re.finditer(r'(COL_[A-Z]+)\s*=\s*"([0-9A-Fa-f]{6})"', src):
        vals.setdefault(m.group(1), m.group(2).upper())
    return vals


def main():
    osc = osc_colours()
    menu = script_colours("juxtopposed-menu.lua")
    home = script_colours("juxtopposed-home.lua")
    bar = osc["background_color"]
    panel = menu["COL_BG"]
    home_bg = home["COL_BG"]
    hover = menu["COL_HOVER"]
    fg = menu["COL_FG"]
    dim = menu["COL_DIM"]
    accent = osc["buttons_color"]
    track = "090909"  # cone track colour (osc.lua, juxt_volume_content)
    line = menu["COL_LINE"]

    checks = [
        # (what, foreground, background, minimum, kind)
        ("bar text: title", osc["title_color"], bar, 4.5, "text"),
        ("bar text: time", osc["timecode_color"], bar, 4.5, "text"),
        ("bar icons: buttons", osc["buttons_color"], bar, 3.0, "icon"),
        ("bar icons: top buttons", osc["top_buttons_color"], bar, 3.0, "icon"),
        ("bar icon: play on accent", "111111", accent, 3.0, "icon"),
        ("dim text on bar (title)", dim, bar, 4.5, "text"),
        ("menu text", fg, panel, 4.5, "text"),
        ("menu dim arrow", dim, panel, 4.5, "text"),
        ("menu selected row vs card", hover, panel, 1.0, "info"),
        ("menu selection marker", fg, hover, 3.0, "icon"),
        ("menu separator", line, panel, 1.0, "info"),
        ("home text", home["COL_FG"], home_bg, 4.5, "text"),
        ("home dim text", home["COL_DIM"], home_bg, 4.5, "text"),
        ("home selected row vs view", home["COL_HOVER"], home_bg, 1.0, "info"),
        ("home selection marker", home["COL_FG"], home["COL_HOVER"], 3.0, "icon"),
        ("seek fill vs track", osc["timecode_color"], line, 3.0, "icon"),
        ("cone fill vs track", accent, track, 3.0, "icon"),
        ("speaker icon on bar", accent, bar, 3.0, "icon"),
    ]

    failed = 0
    width = max(len(c[0]) for c in checks)
    for what, f, b, need, kind in checks:
        r = ratio(f, b)
        ok = r >= need
        failed += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} {what:<{width}}  #{f} on #{b}  {r:5.2f}:1  (needs {need}:1, {kind})")
    print()
    print(f"{len(checks) - failed} of {len(checks)} pass")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
