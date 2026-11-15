#!/usr/bin/env python3
"""Generate the juxtopposed OSC icon data from the VLC (juxtopposed) redesign SVGs.

Writes a Lua block between the markers in player/lua/osc.lua:

    -- BEGIN juxtopposed icons ... -- END juxtopposed icons

Every icon is a list of polygons (flat x,y arrays in 1/1 px of the icon's own 24-unit box, origin
at the top-left of the viewBox). Curves are sampled into straight segments. Stroked paths (the menu
set) are converted into thin filled quads, because ASS cannot stroke open lines.

Usage: python3 redesign/tools/make_icons.py [path-to-vlc-qt-redesign-fork]
"""
import math
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VLC = os.environ.get("VLC_REDESIGN_TREE") or os.path.expanduser(
    "~/Documents/code/vlc-qt-redesign-fork")
PIX = os.path.join(VLC, "modules/gui/qt/pixmaps")
PROTO_CHROME = os.path.expanduser("~/Documents/code/vlc-prototype/js/chrome-icons.js")
OSC = os.path.join(ROOT, "player/lua/osc.lua")

BEGIN = "-- BEGIN juxtopposed icons"
END = "-- END juxtopposed icons"

# OSC name -> SVG path relative to modules/gui/qt/pixmaps
ICONS = {
    "play": "icons/redesign/play_filled.svg",
    "pause": "icons/redesign/pause_filled.svg",
    "prev": "icons/redesign/previous.svg",
    "next": "icons/redesign/next.svg",
    "skip_backward": "icons/redesign/skip_back.svg",
    "skip_forward": "icons/redesign/skip_for.svg",
    "menu": "icons/redesign/ellipsis.svg",
    "home": "icons/redesign/home.svg",
    "fullscreen": "icons/redesign/fullscreen.svg",
    "exit_fullscreen": "icons/redesign/defullscreen.svg",
    "mute": "icons/redesign/volume_muted.svg",
    "volume": "icons/redesign/volume_high.svg",
    "audio": "menu/redesign-audio.svg",
    "subtitle": "menu/redesign-subtitle.svg",
    # menu set (player and Home three-dot menus)
    "m_file": "menu/redesign-file.svg",
    "m_folder": "menu/redesign-folder.svg",
    "m_openmedia": "menu/redesign-openmedia.svg",
    "m_play": "menu/redesign-play.svg",
    "m_stop": "menu/redesign-stop.svg",
    "m_previous": "menu/redesign-previous.svg",
    "m_next": "menu/redesign-next.svg",
    "m_playback": "menu/redesign-playback.svg",
    "m_video": "menu/redesign-video.svg",
    "m_audio": "menu/redesign-audio.svg",
    "m_subtitle": "menu/redesign-subtitle.svg",
    "m_moresettings": "menu/redesign-moresettings.svg",
    "m_quit": "menu/redesign-quit.svg",
    "m_queue": "menu/redesign-queue.svg",
    "m_resync": "menu/redesign-resync.svg",
    "m_settings": "menu/redesign-settings.svg",
}

NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
CMD = re.compile(r"[MmLlHhVvCcSsZz]")


def parse_path(d):
    """Return a list of subpaths; each is (points, closed). Supports M L H V C S Z (abs and rel)."""
    subpaths = []
    cur = []
    closed = False
    x = y = 0.0
    sx = sy = 0.0
    lastc = None  # last cubic control point for S
    i = 0
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?", d)

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    cmd = None
    while i < len(tokens):
        if tokens[i].isalpha():
            if not CMD.fullmatch(tokens[i]):
                raise ValueError("unsupported path command " + tokens[i])
            cmd = tokens[i]
            i += 1
            if cmd in "Zz":
                if cur:
                    subpaths.append((cur, True))
                cur = []
                x, y = sx, sy
                lastc = None
                continue
        rel = cmd.islower()
        C = cmd.upper()
        ox, oy = (x, y) if rel else (0.0, 0.0)
        if C == "M":
            if cur:
                subpaths.append((cur, False))
            x, y = ox + num(), oy + num()
            sx, sy = x, y
            cur = [(x, y)]
            cmd = "l" if rel else "L"  # subsequent pairs are implicit lineto
            lastc = None
        elif C == "L":
            x, y = ox + num(), oy + num()
            cur.append((x, y))
            lastc = None
        elif C == "H":
            x = (x if rel else 0.0) + num() if rel else num()
            cur.append((x, y))
            lastc = None
        elif C == "V":
            y = (y if rel else 0.0) + num() if rel else num()
            cur.append((x, y))
            lastc = None
        elif C in "CS":
            if C == "C":
                x1, y1 = ox + num(), oy + num()
            else:
                x1, y1 = (2 * x - lastc[0], 2 * y - lastc[1]) if lastc else (x, y)
            x2, y2 = ox + num(), oy + num()
            x3, y3 = ox + num(), oy + num()
            p0 = (x, y)
            for k in range(1, 9):
                t = k / 8.0
                mt = 1 - t
                px = mt**3 * p0[0] + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t**3 * x3
                py = mt**3 * p0[1] + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t**3 * y3
                cur.append((px, py))
            lastc = (x2, y2)
            x, y = x3, y3
        else:
            raise ValueError("unsupported path command " + cmd)
    if cur:
        subpaths.append((cur, closed))
    return subpaths


def transform_points(points, tx, ty):
    return [(x + tx, y + ty) for x, y in points]


def parse_transform(s):
    if not s:
        return 0.0, 0.0
    m = re.search(r"translate\(\s*([-\d.]+)[ ,]+([-\d.]+)\s*\)", s)
    return (float(m.group(1)), float(m.group(2))) if m else (0.0, 0.0)


def signed_area(poly):
    a = 0.0
    for k in range(len(poly)):
        x1, y1 = poly[k]
        x2, y2 = poly[(k + 1) % len(poly)]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def ccw(poly):
    return poly if signed_area(poly) >= 0 else list(reversed(poly))


def stroke_quads(points, closed, hw):
    """Thin quads along each segment of a polyline (butt ends, consistent winding)."""
    quads = []
    segs = list(zip(points, points[1:]))
    if closed and len(points) > 2:
        segs.append((points[-1], points[0]))
    for (ax, ay), (bx, by) in segs:
        dx, dy = bx - ax, by - ay
        ln = math.hypot(dx, dy)
        if ln < 1e-9:
            continue
        nx, ny = -dy / ln * hw, dx / ln * hw
        quad = [(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)]
        quads.append(ccw(quad))
    return quads


def svg_polygons(path, origin=(0.0, 0.0)):
    """All polygons of one SVG file, origin-shifted to the top-left of its viewBox."""
    s = open(path, encoding="utf-8").read()
    vb = re.search(r'viewBox="([^"]+)"', s).group(1).split()
    vx, vy = float(vb[0]), float(vb[1])
    polys = []
    for m in re.finditer(r"<path\b([^>]*)/?>", s):
        attrs = m.group(1)
        d = re.search(r'\bd="([^"]+)"', attrs).group(1)
        tx, ty = parse_transform(re.search(r'transform="([^"]*)"', attrs).group(1)
                                 if 'transform="' in attrs else "")
        is_stroke = 'stroke="' in attrs and 'stroke="none"' not in attrs
        sw_m = re.search(r'stroke-width="([\d.]+)"', attrs)
        sw = float(sw_m.group(1)) if sw_m else 1.5
        for pts, closed in parse_path(d):
            pts = transform_points(pts, tx - vx, ty - vy)
            if len(pts) < 2:
                continue
            if is_stroke:
                polys.extend(stroke_quads(pts, closed, sw / 2.0))
            elif len(pts) >= 3:
                polys.append(pts)
    return polys


def flat(polys):
    return [[round(c, 2) for xy in poly for c in xy] for poly in polys]


def lua_polys(name, polys):
    body = ",\n        ".join("{" + ",".join(str(c) for c in p) + "}" for p in polys)
    return "    %s = {\n        %s,\n    },\n" % (name, body)


def cone_polys():
    """VLC's volume cone (track + fill) from the prototype's chrome-icons.js, 91x30 box, origin 1627,1038."""
    js = open(PROTO_CHROME, encoding="utf-8").read()
    track = re.search(r'"cone_track": "([^"]+)"', js).group(1)
    fill = re.search(r'"cone_fill": "([^"]+)"', js).group(1)
    out = {}
    for key, d in (("track", track), ("fill", fill)):
        polys = []
        for pts, closed in parse_path(d):
            pts = transform_points(pts, -1627.0, -1038.0)
            if len(pts) >= 3:
                polys.append(pts)
        out[key] = polys
    return out


def build_block():
    parts = []
    parts.append(BEGIN + " (generated by redesign/tools/make_icons.py, do not edit by hand)")
    parts.append("local juxt_icon_polys = {")
    for name, rel in ICONS.items():
        polys = svg_polygons(os.path.join(PIX, rel))
        parts.append(lua_polys(name, flat(polys)).rstrip())
    parts.append("}")
    cone = cone_polys()
    parts.append("local juxt_cone_polys = {")
    parts.append(lua_polys("track", flat(cone["track"])).rstrip())
    parts.append(lua_polys("fill", flat(cone["fill"])).rstrip())
    parts.append("}")
    parts.append(END)
    return "\n".join(parts) + "\n"


SHARED = os.path.join(ROOT, "redesign", "bundle", "scripts", "juxtopposed-icons.lua")


def build_shared():
    """A standalone Lua module with the same polygons, for the bundle's menu and Home scripts."""
    lines = ["-- generated by redesign/tools/make_icons.py from the VLC (juxtopposed) redesign SVGs; do not edit",
             "-- polygons: flat x,y arrays in px of a 24 box (cone: 91x30 box, origin top-left)",
             "local M = {}", "M.polys = {"]
    for name, rel in ICONS.items():
        polys = flat(svg_polygons(os.path.join(PIX, rel)))
        lines.append(lua_polys(name, polys).rstrip())
    lines.append("}")
    cone = cone_polys()
    lines.append("M.cone = {")
    lines.append(lua_polys("track", flat(cone["track"])).rstrip())
    lines.append(lua_polys("fill", flat(cone["fill"])).rstrip())
    lines.append("}")
    lines.append("return M")
    return "\n".join(lines) + "\n"


def main():
    os.makedirs(os.path.dirname(SHARED), exist_ok=True)
    open(SHARED, "w", encoding="utf-8").write(build_shared())
    print("wrote", SHARED)
    block = build_block()
    src = open(OSC, encoding="utf-8").read()
    if BEGIN in src:
        pre = src[: src.index(BEGIN)]
        post = src[src.index(END) + len(END):]
        new = pre + block.rstrip("\n") + post
    else:
        anchor = "local icon_styles = {"
        assert src.count(anchor) == 1
        new = src.replace(anchor, block + anchor)
    open(OSC, "w", encoding="utf-8").write(new)
    print("wrote icon block to", OSC, "(%d bytes)" % len(block))


if __name__ == "__main__":
    if len(sys.argv) > 1:  # optional: the VLC tree to read, as the first argument
        PIX = os.path.join(sys.argv[1], "modules/gui/qt/pixmaps")
    main()
