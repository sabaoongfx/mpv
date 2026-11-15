# juxtopposed redesign: notes for Claude

Working notes for the mpv redesign (VLC-style look and UX). Read this before changing the bundle.
Plan and research: `PLAN.md`. Install steps: `bundle/README.md`. Tests: `tests/README.md`.

## Where things are

- Branch `redesign` in the fork `https://github.com/sabaoongfx/mpv.git` (remote `fork`). Latest pushed: `0eb92ff533`.
- The on-screen controller is `player/lua/osc.lua` (embedded in the mpv binary). Layout code is `juxt_bar_layout()`,
  icons are `juxt_build_icons()`, the volume wedge is `juxt_volume_content()`.
- The bundle (config and scripts) is `redesign/bundle/`:
  - `mpv.conf`: `idle=yes`, `force-window=yes`, `geometry=1280x720`, watch history and resume settings.
  - `osc.conf`: layout and icon style, `juxt_title=no`, the menu and button commands.
  - `scripts/juxtopposed-menu.lua`: three-dot menus, audio and subtitle popups, Open File and Open Folder.
  - `scripts/juxtopposed-home.lua`: Home view (Continue Watching, Listen Again), video thumbnails, window title.
  - `scripts/juxtopposed-start.lua`: bar shows for 10 s when a file starts.
  - `scripts/juxtopposed-icons.lua`: generated from VLC SVGs by `tools/make_icons.py`. Do not edit by hand.
  - `bin/juxt-pick-file.py`: file chooser through the xdg desktop portal (PyGObject).
- The user's installed copy: `~/.config/mpv-juxtopposed/` (copy the bundle there after editing), build at
  `~/.local/opt/mpv-juxtopposed/`, launcher `~/.local/bin/mpv-juxt`, desktop entry on the Desktop.

## Build and install

- Build: `ninja -C build` (meson). Install: `meson install -C build --no-rebuild` with the venv meson that the session
  created in the scratchpad. Install goes to `~/.local/opt/mpv-juxtopposed`.
- Run the installed build with `LD_LIBRARY_PATH=$HOME/.local/opt/mpv-juxtopposed/lib`. Without it mpv does not start
  and the test scripts fail with "did not open its IPC socket".
- Lua scripts need no rebuild; copy them to `~/.config/mpv-juxtopposed/scripts/`. Menu and Home changes take effect
  when mpv restarts.

## Tests (run them when asked, see `tests/README.md`)

- `cd redesign/tests/lua && lua5.4 run.lua`: 27 Lua tests against a stub of the mpv API. Add `set_property`,
  `commandv` and similar to `stub_mp.lua` when a script starts using them, or every test in that file fails.
- `tests/smoke/bar_clicks.py` (15 checks, under `xvfb-run`): clicks each control and checks IPC state and pixels.
- `tests/smoke/home_crash.py`, `screens.py`, `ipc_smoke.py`: X11 checks. Frames come from ffmpeg `x11grab`.
- Click tests move the pointer, wait 0.4 s, then click. Without the wait the click lands before the bar updates.

## What the user has asked for (keep to this)

- Look and placement follow the VLC redesign; keep mpv's own accent colours. No playlist, no disk or network entries.
- Top strip 32 px, bottom bar 44 px, controls 24 px. The title is not repeated in the top strip (the window title shows it).
- Audio and subtitle buttons open VLC-style popups (tracks with a check, output devices or Add subtitles).
- Home: Continue Watching and Listen Again. Thumbnails are real frames (see below). The window title is "Home" while
  Home shows. Text sizes match the HTML prototype (`prototype.html`), checked at 1280 px wide.
- The window opens at 1280x720: text is scaled to the window height, so a small window makes the text small.

## Things that bit us (check these first when something looks wrong)

- **Overlay ids** for `overlay-add` must be 0..63. Id 1000 fails with "invalid id". Thumbnails use 40..63.
- **Overlays stay drawn** unless removed. `clear_overlays()` must remove them directly. `sync_overlays()` skips an
  unchanged frame, so it cannot be used to clear.
- **Thumbnails are raw BGRA** (144x80, cached under `~/.cache/mpv-juxtopposed/thumbs`). They come from ffprobe and
  ffmpeg at 15% of the duration, run asynchronously.
- **Many tiny ASS rectangles** (`\p4` drawings, 1–2 px tall) render with gaps. Use a few large rectangles.
- **ASS font sizes** come out at about two-thirds of the number given, so sizes were scaled up to match the prototype.
- **Resume files**: mpv writes a position only on quit and removes the file when it starts again. Home therefore writes
  `write-watch-later-config` every 5 s while a local file plays.
- **Window title**: set the `options/title` option, not the `title` property. mpv rewrites the title when it stops.
  Reading the `title` property returns the template text, which is not what the window shows.
- **Menus**: header rows are not selectable (`selectable()`). Hit tests must skip headers too.
- **Subtitle button** stays enabled in the juxtopposed layout even with no subtitle track, so Add subtitles is reachable.
- **Folders**: mpv cannot play a folder path. Open Folder queues the media files in the folder.
- **Open File / Open Folder** use the xdg file-chooser portal. zenity and kdialog are not installed on the user's
  machine. Tk is broken here.
- **Killing test processes**: `pkill -f` with a loose pattern killed the shell once. Use an anchored pattern.

## Open items

- Home crash on the user's Wayland/GPU setup: not reproduced on X11 (`home_crash.py` passes). The user's log showed a
  clean quit. Needs logs from their session.
- Open Folder: the portal's directory mode and the folder queueing are untested from the menu. Ask for
  `~/juxt-menu.log` if it does nothing.
- Hand cursor over buttons needs a C change in mpv. Not started; the user has not answered.
- Chapter ticks on the seek bar: not hidden; the user has not answered.
- The stock `select` pickers are not restyled. Only the audio and subtitle popups are.
- Thumbnails on audio rows use the gradient, not album art.
