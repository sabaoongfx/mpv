-- Tests for redesign/bundle/scripts/juxtopposed-menu.lua
-- Items on the player menu, top level (separators are skipped by Up and Down):
--   1 Play / Pause   2 Stop   (sep)   4 Previous Item   5 Next Item   (sep)
--   7 Playback   8 Video   9 Audio   10 Subtitle   (sep)   12 More Settings   (sep)   14 Quit

local stub = require "stub_mp"

local HERE = _G.JUXT_TEST_DIR or os.getenv("JUXT_TEST_DIR") or "."
local SCRIPT = HERE .. "/../../bundle/scripts/juxtopposed-menu.lua"
local SCRIPT_DIR = HERE .. "/../../bundle/scripts"

local function load()
    return stub.load(SCRIPT, { dir = SCRIPT_DIR, props = { ["mouse-pos"] = { x = 0, y = 0 } } })
end

local function has(s, text)
    return string.find(s, text, 1, true) ~= nil
end

local tests = {}

tests[#tests + 1] = { "opening the player menu draws its labels and the first selection", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    local d = mp.overlay.data
    assert(has(d, "Play / Pause"), "first item missing")
    assert(has(d, "Quit"), "last item missing")
    assert(has(d, "242424"), "selected row colour missing: the keyboard selection must be visible")
    assert(mp.keys["juxt-menu-up"] and mp.keys["juxt-menu-enter"], "keys not bound while open")
end }

tests[#tests + 1] = { "Down skips separators", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    stub.key(mp, "juxt-menu-down") -- 1 -> 2 (Stop)
    stub.key(mp, "juxt-menu-down") -- 2 -> 4 (Previous Item), the separator at 3 is skipped
    stub.key(mp, "juxt-menu-enter")
    assert(mp.commands[#mp.commands] == "playlist-prev", "expected playlist-prev, got " .. tostring(mp.commands[#mp.commands]))
end }

tests[#tests + 1] = { "Up from the first item wraps to the last", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    stub.key(mp, "juxt-menu-up")
    stub.key(mp, "juxt-menu-enter")
    assert(mp.commands[#mp.commands] == "quit", "expected quit, got " .. tostring(mp.commands[#mp.commands]))
end }

tests[#tests + 1] = { "Enter on a command runs it and closes the menu", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    stub.key(mp, "juxt-menu-enter") -- Play / Pause
    assert(mp.commands[#mp.commands] == "cycle pause", "expected cycle pause")
    assert(mp.overlay.data == "", "menu should be cleared after running an item")
    assert(mp.keys["juxt-menu-up"] == nil, "key bindings should be removed on close")
end }

tests[#tests + 1] = { "submenus open with Right and go back with Left, then Esc closes", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    for _ = 1, 4 do stub.key(mp, "juxt-menu-down") end -- to Playback (7)
    stub.key(mp, "juxt-menu-right")
    assert(has(mp.overlay.data, "Slower"), "Playback submenu not shown")
    stub.key(mp, "juxt-menu-left")
    assert(has(mp.overlay.data, "Play / Pause") and not has(mp.overlay.data, "Slower"), "Left should return to the top level")
    stub.key(mp, "juxt-menu-esc")
    assert(mp.overlay.data == "", "Esc at the top level should close the menu")
end }

tests[#tests + 1] = { "a click outside the card closes the menu", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    mp.props["mouse-pos"] = { x = 2000, y = 2000 }
    stub.key(mp, "juxt-menu-click")
    assert(mp.overlay.data == "", "click outside should close")
end }

tests[#tests + 1] = { "a click on a row runs it", function()
    local mp = load()
    stub.message(mp, "juxt-menu")
    -- The player menu opens under its button in the top strip: top at 44 px.
    local card_y = 44
    mp.props["mouse-pos"] = { x = 100, y = card_y + 4 + 16 }
    stub.key(mp, "juxt-menu-click")
    assert(mp.commands[#mp.commands] == "cycle pause", "clicking the first row should play/pause, got " .. tostring(mp.commands[#mp.commands]))
end }

tests[#tests + 1] = { "the Home menu lists the open and Home entries", function()
    local mp = load()
    stub.message(mp, "juxt-menu-home")
    local d = mp.overlay.data
    assert(has(d, "Open File(s)") and has(d, "Open from Clipboard") and has(d, "Play all"), "Home menu entries missing")
end }

tests[#tests + 1] = { "a command with ';' runs as two mpv commands", function()
    local mp = load()
    stub.message(mp, "juxt-menu-home")
    -- Items: 1 Open File(s), 2 Open Folder, 3 Open from Clipboard, (sep), 5 Play all
    for _ = 1, 2 do stub.key(mp, "juxt-menu-down") end
    stub.key(mp, "juxt-menu-enter")
    local n = #mp.commands
    assert(mp.commands[n - 1] == "update-clipboard text", "first command: " .. tostring(mp.commands[n - 1]))
    assert(mp.commands[n] == "loadfile ${clipboard/text}", "second command: " .. tostring(mp.commands[n]))
end }

tests[#tests + 1] = { "Open File(s) asks the desktop file chooser helper and plays what it returns", function()
    local mp = stub.load(SCRIPT, { dir = SCRIPT_DIR, pick_stdout = "/media/a.mkv\n/media/b.mkv\n",
        props = { ["mouse-pos"] = { x = 0, y = 0 } } })
    stub.message(mp, "juxt-menu-home")
    stub.key(mp, "juxt-menu-enter") -- Open File(s)
    local call = mp.async_calls[1]
    assert(call and call.args[1] == "python3" and call.args[2]:match("juxt%-pick%-file%.py$") and call.args[3] == "file",
        "expected the helper to be called in file mode")
    assert(mp.commands[#mp.commands - 1] == "loadfile|/media/a.mkv|replace", "first file should replace")
    assert(mp.commands[#mp.commands] == "loadfile|/media/b.mkv|append-play", "second file should append")
end }

return tests
