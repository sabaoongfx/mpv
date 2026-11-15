#!/usr/bin/env python3
"""Screenshot check for the juxtopposed look, run against a built mpv on a real X display.

Needs DISPLAY (an Xvfb screen of 1280x720) and ffmpeg (x11grab). It starts mpv with the bundle
installed, takes three captures, and checks the pixels where the design says they must be:

  home.png    Home view: the background is drawn (#0E0E0E covers most of the screen)
  player.png  player bar: the bottom 56 px are the bar colour (#1B1B1B) with light icons and text
  menu.png    player menu: the card colour (#181818) is drawn at the bottom left

The PNGs go to the output folder given on the command line, so they can be uploaded as artifacts.

Usage: screens.py <mpv binary> <config dir> <output dir>
"""
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ipc_smoke import MSG_LEVEL, send, start  # noqa: E402

W, H = 1280, 720


def capture(display, png_path):
    """Save a PNG of the display and return its raw RGB bytes."""
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab", "-video_size", f"{W}x{H}",
                    "-i", display, "-frames:v", "1", png_path], check=True)
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "x11grab", "-video_size", f"{W}x{H}",
                          "-i", display, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    if len(raw) != W * H * 3:
        raise RuntimeError(f"capture has {len(raw)} bytes, expected {W * H * 3}")
    return raw


def pixel_stats(raw, x0, y0, x1, y1, colour, tol):
    """Share of pixels in the box that are within `tol` of `colour`, and count of light pixels."""
    cr, cg, cb = colour
    near = light = total = 0
    for y in range(y0, y1):
        row = (y * W) * 3
        for x in range(x0, x1):
            i = row + x * 3
            r, g, b = raw[i], raw[i + 1], raw[i + 2]
            total += 1
            if abs(r - cr) <= tol and abs(g - cg) <= tol and abs(b - cb) <= tol:
                near += 1
            if r >= 200 and g >= 200 and b >= 200:
                light += 1
    return near / total, light


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    mpv, config, out = sys.argv[1], sys.argv[2], sys.argv[3]
    display = os.environ.get("DISPLAY")
    if not display:
        print("DISPLAY is not set: run this under an X server (Xvfb)")
        return 2
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="juxt-shots-")
    checks = []

    proc, sock, log = start(mpv, config, work,
                            ["--vo=x11", "--ao=null", "--force-window=yes", "--geometry=1280x720+0+0"],
                            MSG_LEVEL)
    try:
        time.sleep(3)
        raw = capture(display, os.path.join(out, "home.png"))
        share, light = pixel_stats(raw, 0, 0, W, H, (14, 14, 14), 8)
        checks.append(("home background drawn", share >= 0.7, f"{share:.2f} of the screen"))

        send(sock, ["loadfile", "av://lavfi:testsrc2=size=1280x720:rate=25", "replace"])
        time.sleep(3)
        send(sock, ["set_property", "pause", True])
        send(sock, ["script-message", "osc-visibility", "always"])
        time.sleep(2)
        raw = capture(display, os.path.join(out, "player.png"))
        share, light = pixel_stats(raw, 0, H - 56, W, H, (27, 27, 27), 6)
        checks.append(("player bar drawn", share >= 0.5, f"{share:.2f} of the bar"))
        checks.append(("bar has light icons and text", light >= 100, f"{light} light pixels"))

        send(sock, ["script-message", "juxt-menu"])
        time.sleep(2)
        raw = capture(display, os.path.join(out, "menu.png"))
        share, _ = pixel_stats(raw, 12, 200, 260, 600, (24, 24, 24), 6)
        checks.append(("player menu card drawn", share >= 0.5, f"{share:.2f} of the card"))

        send(sock, ["quit"])
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
    finally:
        if proc.poll() is None:
            proc.kill()

    failed = 0
    for name, ok, detail in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
        failed += 0 if ok else 1
    print(f"log: {log}")
    print(f"screenshots: {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
