#!/usr/bin/env python3
"""Click test for the juxtopposed bar (bottom controls and top row), on a real X display.

Clicks each control with xdotool and reads what mpv did through its IPC socket. Positions are for
a 1280x720 window at +0+0 (the bar layout in player/lua/osc.lua, juxt_bar_layout).

Usage: bar_clicks.py <mpv binary> <config dir> <media file> <output dir>   (run under Xvfb)
"""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ipc_smoke import MSG_LEVEL, send, start  # noqa: E402
from screens import capture, pixel_stats  # noqa: E402

# Click points (x, y) at 1280x720, from the layout: top strip centre y 20, control row centre y 705
MENU = (22, 20)
HOME_BTN = (54, 20)
PLAY = (30, 705)
BACK10 = (84, 705)
FWD10 = (122, 705)
PREV = (160, 705)
NEXT = (198, 705)
SEEK = (600, 705)          # seek bar runs x 290..965
AUDIO = (1057, 705)
SUBS = (1095, 705)
SPEAKER = (1125, 705)      # volume: speaker x 1117..1135
CONE_HALF = (1117 + 26 + 45, 705)  # the wedge (x 1143..1234) at about half
FULLSCREEN = (1256, 705)
OFF_BAR = (600, 300)       # the video, to close menus


def click(x, y):
    # move first and let the OSC update its mouse area, then click (a person moves, then clicks)
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], check=True)
    time.sleep(0.4)
    subprocess.run(["xdotool", "click", "1"], check=True)
    time.sleep(0.7)


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    mpv, config, media, out = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="juxt-clicks-")
    proc, sock, log = start(mpv, config, work,
                            ["--vo=x11", "--ao=null", "--force-window=yes", "--geometry=1280x720+0+0",
                             "--script-opts=osc-hidetimeout=60000"], MSG_LEVEL)
    results = []
    display = os.environ["DISPLAY"]

    def prop(name):
        return json.loads(send(sock, ["get_property", name])).get("data")

    def show():
        # the bar hides 10 s after a file starts (juxtopposed-start.lua), so show it before each section
        send(sock, ["script-message", "osc-visibility", "always"])
        time.sleep(1.0)

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    try:
        time.sleep(1)
        send(sock, ["loadfile", media, "replace"])
        send(sock, ["loadfile", os.path.join(os.path.dirname(media), "song.flac"), "append"])
        time.sleep(3)
        send(sock, ["script-message", "osc-visibility", "always"])
        time.sleep(1.5)

        # play / pause
        p0 = prop("pause")
        click(*PLAY)
        p1 = prop("pause")
        click(*PLAY)
        p2 = prop("pause")
        check("play/pause toggles", p1 != p0 and p2 == p0, f"pause {p0} -> {p1} -> {p2}")

        show()
        # skip back and forward 10 s (start at 30 s so the skip back is not clamped at 0)
        send(sock, ["seek", 30, "absolute"])
        time.sleep(1)
        t0 = prop("time-pos")
        click(*BACK10)
        time.sleep(0.5)
        t1 = prop("time-pos")
        check("skip back 10 s", t1 is not None and t0 is not None and t1 < t0 - 7,
              f"{t0:.1f} -> {t1:.1f}")
        t2 = prop("time-pos")
        click(*FWD10)
        time.sleep(0.5)
        t3 = prop("time-pos")
        check("skip forward 10 s", t3 is not None and t2 is not None and t3 > t2 + 7,
              f"{t2:.1f} -> {t3:.1f}")

        show()
        # seek bar: half way along the bar
        dur = prop("duration")
        click(*SEEK)
        time.sleep(0.5)
        t4 = prop("time-pos")
        frac = (SEEK[0] - 290) / 675.0
        check("seek bar click", dur and t4 is not None and abs(t4 - frac * dur) < 4,
              f"expected about {frac * dur:.0f} s, got {t4:.1f} s (duration {dur:.0f} s)")

        show()
        # playlist next and previous
        i0 = prop("playlist-pos")
        click(*NEXT)
        time.sleep(1)
        i1 = prop("playlist-pos")
        click(*PREV)
        time.sleep(1)
        i2 = prop("playlist-pos")
        check("playlist next and previous", i1 == i0 + 1 and i2 == i0,
              f"playlist-pos {i0} -> {i1} -> {i2}")

        show()
        # volume: the cone sets it, the speaker mutes
        click(*CONE_HALF)
        v = prop("volume")
        check("volume cone click sets the level", v is not None and 35 <= v <= 65, f"volume {v}")
        m0 = prop("mute")
        click(*SPEAKER)
        m1 = prop("mute")
        click(*SPEAKER)
        m2 = prop("mute")
        check("speaker mutes and unmutes", m1 != m0 and m2 == m0, f"mute {m0} -> {m1} -> {m2}")

        show()
        # fullscreen
        f0 = prop("fullscreen")
        click(*FULLSCREEN)
        time.sleep(0.5)
        f1 = prop("fullscreen")
        click(*FULLSCREEN)
        time.sleep(0.5)
        f2 = prop("fullscreen")
        check("fullscreen button", f1 != f0 and f2 == f0, f"fullscreen {f0} -> {f1} -> {f2}")

        show()
        # audio and subtitle buttons open their track menus (checked by a screenshot of the card)
        click(*AUDIO)
        time.sleep(1)
        # the track picker (mpv's select.lua) opens above the bar, around x 507..773, y 314..405
        raw = capture(display, os.path.join(out, "audio-menu.png"))
        _, light = pixel_stats(raw, 500, 300, 780, 420, (0, 0, 0), 0)
        check("audio button opens the track picker", light >= 100, f"{light} light pixels in the picker")
        click(*OFF_BAR)
        click(*SUBS)
        time.sleep(1)
        click(*OFF_BAR)

        show()
        # top row: the three-dot menu
        click(*MENU)
        time.sleep(1)
        raw = capture(display, os.path.join(out, "menu.png"))
        share, _ = pixel_stats(raw, 12, 50, 260, 420, (24, 24, 24), 6)
        check("menu button opens the player menu", share > 0.5, f"{share:.2f} of the card")
        click(*OFF_BAR)
        time.sleep(0.5)
        raw = capture(display, os.path.join(out, "menu-closed.png"))
        share, _ = pixel_stats(raw, 12, 50, 260, 420, (24, 24, 24), 6)
        check("a click outside closes the menu", share < 0.1, f"{share:.2f} of the card still shown")

        show()
        # Home button: stops playback and shows Home
        click(*HOME_BTN)
        time.sleep(1.5)
        idle = prop("idle-active")
        raw = capture(display, os.path.join(out, "home.png"))
        share, _ = pixel_stats(raw, 0, 0, 1280, 720, (14, 14, 14), 8)
        check("home button stops playback and shows Home", idle is True and share > 0.7,
              f"idle-active {idle}, {share:.2f} of the screen is Home background")

        # Home's three dots open the Home menu
        click(1241, 31)
        time.sleep(1)
        raw = capture(display, os.path.join(out, "home-menu.png"))
        share, _ = pixel_stats(raw, 1012, 46, 1268, 290, (24, 24, 24), 6)
        check("Home three dots open the Home menu", share > 0.5, f"{share:.2f} of the card")

        send(sock, ["quit"])
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
    finally:
        if proc.poll() is None:
            proc.kill()

    with open(log, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    errors = [l for l in lines if ("[e]" in l or "[f]" in l or "Lua error" in l) and
              ("osc" in l or "juxtopposed" in l)]
    results.append(("no Lua errors while clicking", not errors, errors[0] if errors else ""))

    failed = 0
    for name, ok, detail in results:
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
        failed += 0 if ok else 1
    print(f"{len(results) - failed} of {len(results)} pass")
    print(f"log: {log}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
