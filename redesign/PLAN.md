# mpv redesign plan

Reference: `redesign/prototype.html` (open it in a browser). It shows the target look: VLC's icons and
hierarchy, mpv's colour (white accent), the VLC volume cone, a Home view with Continue Watching and
Listen Again, and the top-bar and Home three-dot menus.

Status: implemented, not yet run. Code and config for phases 1 to 6 are in place:
- phase 1 icons: `redesign/tools/make_icons.py` (writes the icon data into `player/lua/osc.lua` and `redesign/bundle/scripts/juxtopposed-icons.lua`)
- phase 2 bars and controls: `juxtopposed` layout and volume cone in `player/lua/osc.lua`
- phase 3 menus: `redesign/bundle/scripts/juxtopposed-menu.lua`
- phase 4 Home: `redesign/bundle/scripts/juxtopposed-home.lua`
- phase 5 accessibility: `redesign/tools/contrast.py` (colours; passes 18 of 18). The screenshot check is not run yet.
- phase 6 packaging: `redesign/bundle/` (README, osc.conf, mpv.conf)
Only Lua syntax has been checked (`luac -p`). mpv has not been run with this code.

## What changes from mpv today

Colours and font can use mpv's own options. The rest needs code, because mpv's on-screen controller
(OSC, `player/lua/osc.lua`) has fixed placement, fixed icons and no home view.

| Area | mpv today | Target (prototype) | How |
|---|---|---|---|
| Colours | options, black and white | dark bar `#1B1B1B`, white accent, grey text | `script-opts` (`background_color`, `timecode_color`, `buttons_color`, ...) |
| Bar background | 2 options | opaque (WCAG: translucent bars failed the contrast check) | `background_color` plus `boxalpha` = 0 |
| Icons | `mpv-osd-symbols` font | VLC redesign set (24 px, filled) | new glyph source (see phase 1) |
| Bottom bar | play, skip, time, seek, audio, sub, vol, fullscreen | same, plus previous and next moved in | layout change (placement) |
| Top bar | menu, title, window buttons | menu, Home, title (no cache) | new control (Home), layout change |
| Volume | slider | VLC wedge (cone) | ASS drawing with a clip |
| Button hierarchy | flat | play is the only strong control; others grey, 28 px, 18 px icons | sizes and colours |
| Menus | `select.lua` text lists | VLC cards: icon, label, shortcut or chevron | restyled menu renderer |
| Home | mpv logo on idle | Continue Watching, Listen Again, three-dot menu | new idle view (phase 4) |

## Decisions needed before phase 1

These are the choices the prototype already assumes. Answer each one, or the plan stops there.

1. **Placement changes are wanted** (previous and next in the bottom bar, Home button, cache removed).
   Earlier you asked for no placement changes; the prototype does move them, so I've treated this as
   approved. Confirm.
2. **Delivery:** patch `player/lua/osc.lua` (add a `juxtopposed` layout, smallest change, upstream conflicts
   on OSC updates), or ship a full OSC replacement script (like uosc; no conflicts, more code). Recommend the
   patch, since the layout code is already in `osc.lua`.
3. **Home while playing:** does the Home button stop playback and show the Home view, or open it over the
   video? Recommend: stop and show Home, as VLC's Home is a separate page.
4. **Watch history on by default:** the home list reads `--save-watch-history` (`~~state/watch_history.jsonl`).
   It is off in mpv by default. Recommend: turn it on in the bundled config, and say so.
5. **Idle screen:** the Home view replaces the mpv logo on idle. Recommend yes.

## Phase 1: icons

- Source: the VLC redesign SVGs (`modules/gui/qt/pixmaps/icons/redesign/` and `pixmaps/menu/redesign-*.svg`).
  Menu icons are two-tone; drop the second colour and use one colour, as the prototype does.
- Build a glyph font from them with FontForge, the way VLC builds `VLCIcons.ttf`
  (`pixmaps/makeIconFont.py`), and load it with `osd-fonts-dir`. Alternative: convert each path to ASS draw
  commands at build time (no font). Recommend the font, since VLC's pipeline already does this.
- Check: every icon in the prototype renders at 18 px and 20 px in a test shot.

## Phase 2: bars and controls

- Layout `juxtopposed` in `osc.lua`: the top and bottom bar positions from the prototype (40 px and 55 px at
  1080p; buttons 28 px tall; play 54x28; icons 18 px; times and secondary icons in `#8F8F8F`).
- Bottom bar: play, skip back, skip forward, previous, next, time, seek, time, audio, subtitles, volume cone,
  fullscreen. Each button runs the same mpv command the stock OSC uses for it.
- Top bar: more (menu), Home, title. The cache text is removed.
- Volume cone: draw VLC's two paths (`js/chrome-icons.js` in `vlc-prototype`) with the fill clipped to the
  volume width (ASS `\clip`). Mouse drag, click and wheel as the prototype does.
- Seek bar: white fill, grey track, handle shown on hover.
- Checks: screenshot the player at 1920x1080 and 1280x720 (`screenshot-to-file <file> window` over
  `--input-ipc-server`). Compare control positions with the prototype's geometry; fail on any shift over 2 px.

## Phase 3: menus

- Player three-dot menu: Play / Pause, Stop, Previous Item, Next Item, Playback, Video, Audio, Subtitle,
  More Settings, Quit VLC (submenus shown with ›). Icons per item. No Playlist entry.
- Home three-dot menu: Open File(s), Open Folder, Open from Clipboard, Play all, Add all to queue, Rescan
  library, Library settings. Only entries mpv can do. No network, disc or capture entries.
- Behaviour: arrow keys, Enter and Escape as in `select.lua`. Commands are the same mpv commands that the
  existing `select.lua` menus run; the new code draws them.
- Checks: each entry runs its command; keyboard navigation through every entry.

## Phase 4: Home view

- Data:
  - Continue Watching: entries from `watch_history.jsonl` (newest first, de-duplicated by path). Position from
    the watch-later file for that path (`start=`, found by the MD5 of the path; see `DOCS/man/mpv.rst`
    RESUMING PLAYBACK). Shown only when a position exists.
  - Listen Again: history entries whose file extension is audio (flac, mp3, ogg, opus, m4a, wav, ...). Titles
    come from the history's title field when present, else the file name. History has no artist or album, so
    the list shows titles and folders only.
- Layout: the prototype's Home view (header with three-dot, Continue Watching rows, Listen Again rows).
- Opening an item loads it and hides Home (decision 3).
- Checks: with an empty history the view shows an empty state (no error); with entries it lists them in order;
  an item whose file is missing is skipped with a message.

## Phase 5: accessibility and polish

- Contrast check on rendered shots: every text and icon colour against its bar background, WCAG AA (4.5:1 text,
  3:1 icons). The prototype's dim text (`#8F8F8F`) on `#1B1B1B` passes; anything translucent does not.
- Keyboard: every control and menu entry reachable without a mouse.
- Light theme is not in scope for the first release.

## Phase 6: packaging

- Config bundle: `osc.conf` with the colour options, `watch_history` on, and the `juxtopposed` layout selected.
- Install notes per platform. Instructions to go back to the stock OSC (`osc-layout=bottombar`, old colours).
- Name: confirm the name for the bundle (decision in `redesign/`, see the VLC name "VLC (juxtopposed)").

## Checks (run only when asked)

- Phase 2 and 3 screenshot checks, phase 4 empty and non-empty history runs, phase 5 contrast script.
- `meson setup` and `ninja` still succeed after the `osc.lua` patch (the patch is Lua, so this is a sanity check).

## Not in this plan

Library folders, sidebar, settings window, speed pill, sleep timer, reverse playback, onboarding, the mini player
card, and any playlist screen. The prototype has no playlist view, so none is planned.
