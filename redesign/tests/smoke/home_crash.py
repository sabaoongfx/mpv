#!/usr/bin/env python3
"""Home button test: records the session with ffmpeg, clicks through Home, and checks mpv and the frames.

Steps (positions for a 1280x720 window at +0+0):
  1. play a file, show the bar
  2. click Home (top strip) -> playback stops, the Home view should show
  3. click the first Home row -> that file should play again
  4. click Home again, then quit

Checks: mpv is still running after each step (a crash shows up as an exit), the IPC state changes as
expected, and frames taken from the recording show the Home view and the player bar where they should.
The frames go to the output folder, so they can be looked at.

Usage: home_crash.py <mpv binary> <config dir> <media file> <output dir> [--vo=x11|--vo=gpu]
Needs DISPLAY (Xvfb) and ffmpeg. Run under xvfb-run.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ipc_smoke import MSG_LEVEL, send, start  # noqa: E402

W, H = 1280, 720
HOME_BTN = (54, 20)
FIRST_ROW = (300, 130)   # Home: first row, Continue Watching (or Listen Again when that is the only list)


def click(x, y):
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], check=True)
    time.sleep(0.4)
    subprocess.run(["xdotool", "click", "1"], check=True)


def frame_at(video, t, png):
    """Grab one frame at time t of the recording; returns its raw RGB bytes."""
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{t:.2f}", "-i", video,
                    "-frames:v", "1", png], check=True)
    return subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", f"{t:.2f}", "-i", video,
                           "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                          capture_output=True, check=True).stdout


def share_near(raw, y0, y1, colour, tol):
    """Share of pixels in rows y0..y1 within tol of colour."""
    cr, cg, cb = colour
    near = total = 0
    for y in range(y0, y1, 2):
        row = y * W * 3
        for x in range(0, W, 2):
            i = row + x * 3
            total += 1
            if abs(raw[i] - cr) <= tol and abs(raw[i + 1] - cg) <= tol and abs(raw[i + 2] - cb) <= tol:
                near += 1
    return near / total


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    mpv, config, media, out = sys.argv[1:5]
    vo = sys.argv[5] if len(sys.argv) > 5 else "--vo=x11"
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="juxt-home-")
    display = os.environ["DISPLAY"]
    video = os.path.join(out, "session.mp4")
    # a history with the media file, and a resume position for it, so Home has a row to click
    state = os.path.join(work, "state", "mpv")
    os.makedirs(os.path.join(state, "watch_later"), exist_ok=True)
    with open(os.path.join(state, "watch_history.jsonl"), "w", encoding="utf-8") as f:
        f.write(json.dumps({"time": 1, "path": media, "title": "Test clip"}) + "\n")
    with open(os.path.join(state, "watch_later", "resume"), "w", encoding="utf-8") as f:
        f.write(f"# {media}\nstart=10\n")

    proc, sock, log = start(mpv, config, work,
                            [vo, "--ao=null", "--force-window=yes", "--geometry=1280x720+0+0"], MSG_LEVEL)
    rec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab", "-framerate", "10",
                            "-video_size", f"{W}x{H}", "-i", display, "-c:v", "libx264",
                            "-preset", "ultrafast", "-crf", "28", video], stdin=subprocess.PIPE)
    t0 = time.time()
    events = []
    results = []

    def mark(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    def prop(name):
        return json.loads(send(sock, ["get_property", name])).get("data")

    def step(name):
        events.append((round(time.time() - t0, 2), name))

    try:
        time.sleep(1)
        send(sock, ["loadfile", media, "replace"])
        time.sleep(3)
        send(sock, ["script-message", "osc-visibility", "always"])
        time.sleep(1.5)
        step("playing")
        mark("playing before Home", prop("idle-active") is False and proc.poll() is None,
             f"idle-active {prop('idle-active')}")

        step("click Home")
        click(*HOME_BTN)
        time.sleep(2)
        mark("Home stops playback", prop("idle-active") is True and proc.poll() is None,
             f"idle-active {prop('idle-active')}, mpv alive {proc.poll() is None}")

        step("click the first Home row")
        click(*FIRST_ROW)
        time.sleep(3)
        mark("row plays the file", proc.poll() is None and prop("idle-active") is False,
             f"idle-active {prop('idle-active')}, mpv alive {proc.poll() is None}")

        step("click Home again")
        click(*HOME_BTN)
        time.sleep(2)
        mark("Home again", proc.poll() is None and prop("idle-active") is True,
             f"idle-active {prop('idle-active')}, mpv alive {proc.poll() is None}")

        send(sock, ["quit"])
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            mark("mpv quits", False, "did not quit")
        else:
            mark("mpv quits", True, f"exit status {proc.returncode}")
    finally:
        if proc.poll() is None:
            proc.kill()
        time.sleep(1)
        rec.stdin.write(b"q")
        rec.stdin.flush()
        rec.wait(timeout=30)

    # frames from the recording: a player frame, a Home frame after the click, a row-played frame
    duration = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                     "-of", "csv=p=0", video], capture_output=True,
                                    text=True).stdout.strip() or 0)
    # each frame is taken just before its step (the player) or 2 s after its click (Home, row)
    wanted = {"playing": -0.3, "click Home": 2.0, "click the first Home row": 2.5, "click Home again": 2.0}
    for t, name in events:
        if name not in wanted:
            continue
        when = min(max(t + wanted[name], 0), max(duration - 0.1, 0))
        raw = frame_at(video, when, os.path.join(out, f"frame-{name.replace(' ', '-')}.png"))
        if len(raw) != W * H * 3:
            continue
        if name == "playing":
            bar = share_near(raw, H - 55, H, (27, 27, 27), 6)
            mark("frame while playing shows the bar", bar > 0.4, f"{bar:.2f} bar colour")
        if name == "click Home":
            home = share_near(raw, 0, H, (14, 14, 14), 8)
            mark("frame after Home shows the Home view", home > 0.6, f"{home:.2f} Home background")
        if name == "click the first Home row":
            bar = share_near(raw, H - 55, H, (27, 27, 27), 6)
            mark("frame after the row shows the player bar", bar > 0.4, f"{bar:.2f} bar colour")

    with open(log, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    # errors from the OSC and the scripts only; the demuxer reports damage in the media file itself
    errors = [l for l in lines if ("[e]" in l or "[f]" in l or "Lua error" in l or "traceback" in l)
              and ("osc" in l or "juxtopposed" in l or "Lua" in l or "traceback" in l)]
    mark("no Lua errors", not errors, errors[0][:160] if errors else "")
    shutil.copy(log, os.path.join(out, "mpv.log"))

    failed = 0
    for name, ok, detail in results:
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
        failed += 0 if ok else 1
    print("events:", events)
    print(f"recording: {video}  log: {out}/mpv.log")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
