# juxtopposed tests

Written, not run. Run them only when asked.

| Folder | What it tests | Command |
|---|---|---|
| `lua/` | The menu and Home scripts, and the icon data, with a fake mpv API (`stub_mp.lua`) | `cd redesign/tests/lua && lua run.lua` |
| `python/` | The icon generator (SVG path parsing, stroke quads, drift of the generated files) and the contrast maths | `python3 -m unittest discover -s redesign/tests/python -v` |

## What the Lua tests cover

- `test_menu.lua`: opening, Up and Down (separators skipped, wrap-around), Enter, submenus with Right, Left and Esc, a click outside, a click on a row, the Home menu, a command with `;`, and the no-dialog message.
- `test_home.lua`: a fixture of real files, a watch history and a watch-later folder. It checks Continue Watching (needs a resume position, shows the time, skips missing files), Listen Again, Up, Down, Enter, clicks on rows and on the three dots, Play all, Add all to queue, the empty state, and hiding on idle.
- `test_icons.lua`: every icon polygon is finite and inside the 24 px box, the cone is inside its box, and every icon name the scripts use exists.

## What is not tested

- The OSC layout in `player/lua/osc.lua`. Its helpers are local to that file and mpv runs it at load, so the stub cannot reach them. The screenshot check in `redesign/PLAN.md` (phase 2) covers it.
- Real rendering, key delivery and mouse positions in mpv. The stub only records calls.
- The file dialogs. zenity and kdialog are not called; the stub reports them as missing.
