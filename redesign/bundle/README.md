# juxtopposed bundle: install

The bundle is the config and scripts for the juxtopposed look in mpv. Two parts need care:

1. **The layout and icons are in `player/lua/osc.lua`**, which mpv embeds in its binary. Build mpv
   from this repository, then run that build. A stock mpv will ignore `layout=juxtopposed`.
2. **The menus and the Home view are scripts** in `scripts/`, loaded from the config folder.

## Files

| In this bundle | Copy to (Linux, macOS) | Copy to (Windows, `%APPDATA%\mpv`) |
|---|---|---|
| `mpv.conf` (merge into your file) | `~/.config/mpv/mpv.conf` | `mpv.conf` |
| `osc.conf` | `~/.config/mpv/script-opts/osc.conf` | `script-opts\osc.conf` |
| `scripts/juxtopposed-icons.lua` | `~/.config/mpv/scripts/` | `scripts\` |
| `scripts/juxtopposed-menu.lua` | `~/.config/mpv/scripts/` | `scripts\` |
| `scripts/juxtopposed-home.lua` | `~/.config/mpv/scripts/` | `scripts\` |
| `scripts/juxtopposed-start.lua` | `~/.config/mpv/scripts/` | `scripts\` |

## Build mpv from this repository

Follow `DOCS/compile-windows.md` for Windows, and the usual meson steps elsewhere:

```sh
meson setup build
meson compile -C build
./build/mpv --version
```

Use `./build/mpv` (or install it) for the juxtopposed look. Check that it knows the layout:

```sh
./build/mpv --script-opts=osc-layout=juxtopposed --idle --force-window
```

If the bar shows the classic layout, the config or the build is not the one you think.

## What the bundle does

- **Bar:** the bar shows for 10 seconds when a file starts, then hides until the mouse moves. One opaque bar. Top row: menu (three dots), Home, title. Control row: play, back 10 s,
  forward 10 s, previous, next, time, seek bar, time, audio, subtitles, volume cone, fullscreen.
- **Menu:** the three dots open the player menu. Keys: Up and Down move, Enter or Right opens, Left or
  Esc goes back. Click, or hover and click.
- **Home:** shown when nothing is playing. Continue Watching lists files with a saved position. Listen
  Again lists audio files. The three dots on Home open the Home menu. The Home button stops playback
  and shows Home.
- **Volume:** click the speaker to mute. Click or drag the wedge to set the volume. The wheel also
  works.

## Requirements

- `save-watch-history=yes`, `save-position-on-quit=yes` and `write-filename-in-watch-later-config=yes`
  (in `mpv.conf`). Home reads the history and the resume files.
- `idle=yes` (in `mpv.conf`), so mpv stays open on Home.
- Open File(s) and Open Folder use `zenity` or `kdialog`, whichever is installed. Without either, the
  menu shows a message.

## Uninstall and go back

- Remove the three scripts from `scripts/`, and `script-opts/osc.conf`.
- Remove the lines you merged into `mpv.conf`.
- Run a stock mpv build, or set `layout=bottombar` and `icon_style=classic`.

## Not in this bundle

- Duration and artist in the Home lists. mpv's history stores neither, so rows show the file name and
  the resume time.
- A progress bar on Continue Watching, for the same reason.
- Light theme (see `redesign/PLAN.md`).

## Checks

Colours: `python3 redesign/tools/contrast.py` (prints the WCAG table for the bundle colours).
Screenshots and layout: see `redesign/PLAN.md`, phase 2 (not run yet).
