#!/usr/bin/env python3
"""Headless smoke test for the juxtopposed OSC and scripts, using a built mpv.

Starts mpv with the bundle installed in a throwaway config folder (the same files the install
steps copy), drives it through the IPC socket, and fails on any Lua error, invalid setting, or
missing script in the log. No display is needed: the video output is null.

Usage: ipc_smoke.py <mpv binary> <config dir with mpv.conf, osc.conf and scripts/>
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time


def send(sock_path, command):
    """Send one IPC command and return its reply (one JSON line)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5)
        s.connect(sock_path)
        s.sendall((json.dumps({"command": command}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return data.decode(errors="replace").strip()


def wait_for_socket(path, proc, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.2)
    return False


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    mpv, config = sys.argv[1], sys.argv[2]
    work = tempfile.mkdtemp(prefix="juxt-smoke-")
    sock = os.path.join(work, "mpv.sock")
    log = os.path.join(work, "mpv.log")
    cfg_root = os.path.join(work, "config")
    os.makedirs(os.path.join(cfg_root, "mpv"))
    for name in ("mpv.conf", "osc.conf"):
        src = os.path.join(config, name)
        if os.path.exists(src):
            os.makedirs(os.path.join(cfg_root, "mpv", "script-opts" if name == "osc.conf" else ""), exist_ok=True)
            dst = (os.path.join(cfg_root, "mpv", "script-opts", name) if name == "osc.conf"
                   else os.path.join(cfg_root, "mpv", name))
            with open(src, "rb") as f, open(dst, "wb") as g:
                g.write(f.read())
    scripts_src = os.path.join(config, "scripts")
    scripts_dst = os.path.join(cfg_root, "mpv", "scripts")
    os.makedirs(scripts_dst, exist_ok=True)
    for name in os.listdir(scripts_src):
        if name.endswith(".lua"):
            with open(os.path.join(scripts_src, name), "rb") as f, \
                    open(os.path.join(scripts_dst, name), "wb") as g:
                g.write(f.read())

    env = dict(os.environ, XDG_CONFIG_HOME=cfg_root, XDG_STATE_HOME=os.path.join(work, "state"))
    proc = subprocess.Popen([
        mpv, "--idle=yes", "--vo=null", "--ao=null", "--no-terminal",
        f"--input-ipc-server={sock}", f"--log-file={log}",
        "--msg-level=all=warn,osc=debug,juxtopposed_menu=debug,juxtopposed_home=debug,juxtopposed_icons=debug",
    ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    failures = []
    try:
        if not wait_for_socket(sock, proc):
            print("mpv did not open its IPC socket")
            return 1
        time.sleep(1)
        # Home (idle), the Home menu, then a file with the player bar and the player menu
        send(sock, ["script-message", "juxt-menu-home"])
        send(sock, ["script-message", "juxt-menu-home"])
        send(sock, ["loadfile", "av://lavfi:testsrc2=size=320x240:rate=25", "replace"])
        time.sleep(2)
        send(sock, ["set_property", "pause", True])
        send(sock, ["script-message", "juxt-menu"])
        send(sock, ["script-message", "juxt-menu"])
        send(sock, ["stop"])
        time.sleep(1)
        send(sock, ["script-message", "juxt-home"])
        time.sleep(1)
        send(sock, ["quit"])
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            failures.append("mpv did not quit")
    finally:
        if proc.poll() is None:
            proc.kill()

    with open(log, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    for line in lines:
        if "Lua error" in line or "stack traceback" in line:
            failures.append("lua error: " + line)
        elif "Invalid setting" in line:
            failures.append("invalid setting: " + line)
        elif ("[e]" in line or "[f]" in line) and ("osc" in line or "juxtopposed" in line):
            failures.append("error: " + line)

    for script in ("juxtopposed_menu", "juxtopposed_home", "juxtopposed_icons"):
        if not any(f"[d][{script}] Loading lua script" in line for line in lines):
            failures.append(f"script not loaded: {script}")
    if not any("[d][osc] osc_init" in line for line in lines):
        failures.append("the OSC never initialised")

    print(f"log: {log}")
    if failures:
        print("FAIL")
        for f_ in failures:
            print("  " + f_)
        return 1
    print("OK: scripts loaded, OSC initialised, no Lua errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
