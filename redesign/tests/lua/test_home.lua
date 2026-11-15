-- Tests for redesign/bundle/scripts/juxtopposed-home.lua
-- A fixture directory holds real files, a watch history and a watch-later folder:
--   video1.mkv  has a resume position (754.2 s = 12:34) and a title "Pilot" in the history
--   video2.mp4  is in the history but has no resume position
--   song.flac   is audio, in the history without a title
--   missing.mkv is in the history but the file does not exist

local stub = require "stub_mp"

local HERE = _G.JUXT_TEST_DIR or os.getenv("JUXT_TEST_DIR") or "."
local SCRIPT = HERE .. "/../../bundle/scripts/juxtopposed-home.lua"
local SCRIPT_DIR = HERE .. "/../../bundle/scripts"

local function has(s, text)
    return string.find(s, text, 1, true) ~= nil
end

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text or "")
    f:close()
end

-- A new fixture under a fresh temporary directory.
local function fixture(with_history)
    local root = assert(io.popen("mktemp -d"):read("*l"))
    local media = root .. "/media"
    local state = root .. "/state"
    os.execute("mkdir -p '" .. media .. "' '" .. state .. "/watch_later'")
    local v1, v2, song = media .. "/video1.mkv", media .. "/video2.mp4", media .. "/song.flac"
    write(v1, "x"); write(v2, "x"); write(song, "x")
    write(state .. "/watch_later/aaa", "# " .. v1 .. "\nstart=754.2\n")
    write(state .. "/watch_later/bbb", "# " .. v2 .. "\n")
    local history = root .. "/watch_history.jsonl"
    if with_history ~= false then
        write(history,
            '{"time":1,"path":"' .. v1 .. '","title":"Pilot"}\n' ..
            '{"time":2,"path":"' .. song .. '"}\n' ..
            '{"time":3,"path":"' .. media .. '/missing.mkv"}\n' ..
            '{"time":4,"path":"' .. v2 .. '"}\n')
    end
    return {
        root = root, v1 = v1, v2 = v2, song = song, history = history, state = state,
        opts = {
            dir = SCRIPT_DIR,
            state = state,
            props = {
                ["watch-history-path"] = history,
                ["options/watch-later-dir"] = state .. "/watch_later",
                ["osd-dimensions"] = { w = 1280, h = 720 },
                ["mouse-pos"] = { x = 0, y = 0 },
            },
        },
    }
end

local function show(fx)
    local mp = stub.load(SCRIPT, fx.opts)
    stub.observe(mp, "idle-active", true)
    return mp
end

local tests = {}

tests[#tests + 1] = { "idle shows Home with both sections", function()
    local mp = show(fixture())
    local d = mp.overlay.data
    assert(has(d, "Continue Watching") and has(d, "Listen Again"), "section headings missing")
    assert(has(d, "Pilot"), "history title of the resumable video missing")
    assert(has(d, "song.flac"), "audio file name missing from Listen Again")
end }

tests[#tests + 1] = { "Continue Watching needs a resume position, and shows the time", function()
    local fx = fixture()
    local mp = show(fx)
    local d = mp.overlay.data
    assert(has(d, "Resume at 12:34"), "resume time missing")
    assert(not has(d, "video2.mp4"), "a video without a resume position must not be listed")
end }

tests[#tests + 1] = { "a file that no longer exists is not listed", function()
    local mp = show(fixture())
    assert(not has(mp.overlay.data, "missing.mkv"), "missing file was listed")
end }

tests[#tests + 1] = { "Enter plays the first row", function()
    local fx = fixture()
    local mp = show(fx)
    stub.key(mp, "juxt-home-enter")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.v1 .. "|replace",
        "got " .. tostring(mp.commands[#mp.commands]))
    assert(mp.overlay.data == "", "Home should hide once a file plays")
end }

tests[#tests + 1] = { "Down moves to Listen Again, and Enter plays that song", function()
    local fx = fixture()
    local mp = show(fx)
    stub.key(mp, "juxt-home-down")
    stub.key(mp, "juxt-home-enter")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.song .. "|replace",
        "got " .. tostring(mp.commands[#mp.commands]))
end }

tests[#tests + 1] = { "Up at the first row wraps to the last", function()
    local fx = fixture()
    local mp = show(fx)
    stub.key(mp, "juxt-home-up")
    stub.key(mp, "juxt-home-enter")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.song .. "|replace", "wrap did not reach the last row")
end }

tests[#tests + 1] = { "no history: both sections say nothing is there yet", function()
    local mp = show(fixture(false))
    local d = mp.overlay.data
    local _, count = string.gsub(d, "Nothing here yet", "")
    assert(count == 2, "expected two empty sections, got " .. count)
    assert(has(d, "Play something"), "empty-state hint missing")
end }

tests[#tests + 1] = { "a click on a row plays it", function()
    local fx = fixture()
    local mp = show(fx)
    -- Row 1 of Continue Watching: heading at 80, rows start at 110, 56 px tall
    mp.props["mouse-pos"] = { x = 300, y = 130 }
    stub.key(mp, "juxt-home-click")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.v1 .. "|replace", "row click did not play")
end }

tests[#tests + 1] = { "a click on the three dots opens the Home menu", function()
    local mp = show(fixture())
    -- dots: x = w - 24 - 30 = 1226 .. 1256, y = 16 .. 46
    mp.props["mouse-pos"] = { x = 1240, y = 30 }
    stub.key(mp, "juxt-home-click")
    assert(mp.commands[#mp.commands] == "script-message|juxt-menu-home", "got " .. tostring(mp.commands[#mp.commands]))
end }

tests[#tests + 1] = { "Play all loads the first row, then appends the rest", function()
    local fx = fixture()
    local mp = show(fx)
    stub.message(mp, "juxt-home-play-all")
    assert(mp.commands[#mp.commands - 1] == "loadfile|" .. fx.v1 .. "|replace", "first file")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.song .. "|append-play", "second file")
end }

tests[#tests + 1] = { "Add all to queue appends every row", function()
    local fx = fixture()
    local mp = show(fx)
    stub.message(mp, "juxt-home-queue-all")
    assert(mp.commands[#mp.commands - 1] == "loadfile|" .. fx.v1 .. "|append", "first file")
    assert(mp.commands[#mp.commands] == "loadfile|" .. fx.song .. "|append", "second file")
end }

tests[#tests + 1] = { "playing a file hides Home (idle turns off)", function()
    local mp = show(fixture())
    stub.observe(mp, "idle-active", false)
    assert(mp.overlay.data == "", "Home should be cleared when idle turns off")
    assert(mp.keys["juxt-home-up"] == nil, "key bindings should be removed")
end }

tests[#tests + 1] = { "the Home button's message shows the view again", function()
    local mp = show(fixture())
    stub.observe(mp, "idle-active", false)
    stub.message(mp, "juxt-home")
    assert(has(mp.overlay.data, "Continue Watching"), "juxt-home did not show the view")
end }

return tests
