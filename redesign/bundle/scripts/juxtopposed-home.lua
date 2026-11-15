-- juxtopposed: the Home view, shown when nothing is playing (or after the Home button stops playback).
--
-- Data:
--   Continue Watching  files in the watch history that have a saved resume position
--                      (watch-later files; needs write-filename-in-watch-later-config to find them)
--   Listen Again       audio files in the watch history, newest first
-- Both come from --save-watch-history, which the bundled mpv.conf turns on.
-- mpv keeps no duration or artist in its history, so rows show the resume time and the file name.
--
-- Messages: juxt-home (show the view), juxt-home-play-all, juxt-home-queue-all, juxt-home-refresh
-- Keys while shown: Up/Down move, Enter plays. Mouse: hover highlights, click plays,
-- the three dots (top right) open the Home menu.

local mp = require "mp"
local utils = require "mp.utils"

-- The icon data sits next to this script (or in the config's scripts folder). mpv 0.41 can return
-- no script directory, so try both places.
local function load_icons()
    local tried = {}
    local dir = mp.get_script_directory()
    if dir then tried[#tried + 1] = dir .. "/juxtopposed-icons.lua" end
    local found = mp.find_config_file("scripts/juxtopposed-icons.lua")
    if found then tried[#tried + 1] = found end
    for _, path in ipairs(tried) do
        local ok, m = pcall(dofile, path)
        if ok and m then return m end
    end
    error("juxtopposed-icons.lua not found (looked in: " .. table.concat(tried, ", ") .. ")")
end
local icons = load_icons()

local AUDIO_EXT = { flac = true, mp3 = true, ogg = true, oga = true, opus = true, m4a = true,
                    wav = true, aac = true, wma = true, ape = true, wv = true, alac = true }
local ROW_H, MAX_ROWS = 56, 4
local COL_BG = "0E0E0E"
local COL_PANEL = "2A2927"
local COL_HOVER = "242424" -- selected row (see the menu script)
local COL_LINE = "373737"
local COL_FG = "E3E3E3"
local COL_DIM = "8F8F8F"

local osd = mp.create_osd_overlay("ass-events")
osd.z = -10 -- under the OSC bar, which is drawn at z 0

local st = { shown = false, sel = 1, hover = nil, rows = {}, dots = nil, continue = {}, listen = {} }
local move, enter, click -- defined below; used by the key bindings

local function r8(v) return math.floor(v * 8 + 0.5) end

local function poly_ass(polys, ox, oy, k)
    local out = {}
    for _, p in ipairs(polys) do
        local parts = { "m" }
        for i = 1, #p - 1, 2 do
            parts[#parts + 1] = string.format("%d %d", r8(p[i] * k + ox), r8(p[i + 1] * k + oy))
            if i == 1 then parts[#parts + 1] = "l" end
        end
        out[#out + 1] = table.concat(parts, " ")
    end
    return table.concat(out, " ")
end

local function rect_ass(x, y, w, h)
    return string.format("m %d %d l %d %d %d %d %d %d",
        r8(x), r8(y), r8(x + w), r8(y), r8(x + w), r8(y + h), r8(x), r8(y + h))
end

local function window_size()
    local d = mp.get_property_native("osd-dimensions")
    if not d or not d.w or d.w == 0 then return 1280, 720 end
    return d.w, d.h
end

local function clock(sec)
    sec = math.floor(sec or 0)
    local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function is_local(path)
    return path and not path:find("://", 1, true)
end

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function ext_of(path)
    return (path:match("%.([^./]+)$") or ""):lower()
end

local function base_name(path)
    return path:match("([^/]+)$") or path
end

-- watch-later files: path -> resume position in seconds
local function read_resume()
    local dir = mp.get_property("options/watch-later-dir")
    if not dir or dir == "" then
        dir = "~~state/watch_later"
    end
    dir = mp.command_native({ "expand-path", dir })
    local map = {}
    for _, name in ipairs(utils.readdir(dir, "files") or {}) do
        local f = io.open(dir .. "/" .. name, "r")
        if f then
            local path, start
            for line in f:lines() do
                local p = line:match("^# (.+)$")
                if p and not path then path = p end
                local v = line:match("^start=([%d%.]+)")
                if v then start = tonumber(v) end
            end
            f:close()
            if path and start and start > 0 then map[path] = start end
        end
    end
    return map
end

local function read_history()
    local path = mp.command_native({ "expand-path", mp.get_property("watch-history-path") or "" })
    local f = io.open(path, "r")
    if not f then return {} end
    local entries = {}
    for line in f:lines() do
        local e = utils.parse_json(line)
        if type(e) == "table" and e.path then entries[#entries + 1] = e end
    end
    f:close()
    -- mpv writes a title only when the file has one, so keep the latest title seen for each path
    local titles = {}
    for _, e in ipairs(entries) do
        if e.title then titles[e.path] = e.title end
    end
    local out, seen = {}, {}
    for i = #entries, 1, -1 do -- newest first, one row per file
        local e = entries[i]
        if not seen[e.path] then
            seen[e.path] = true
            e.title = titles[e.path] or e.title
            out[#out + 1] = e
        end
    end
    return out
end

local function load_lists()
    local resume = read_resume()
    st.continue, st.listen = {}, {}
    for _, e in ipairs(read_history()) do
        if is_local(e.path) and exists(e.path) then
            local title = e.title or base_name(e.path)
            if AUDIO_EXT[ext_of(e.path)] then
                if #st.listen < MAX_ROWS then
                    st.listen[#st.listen + 1] = { path = e.path, title = title, kind = "audio" }
                end
            elseif resume[e.path] and #st.continue < MAX_ROWS then
                st.continue[#st.continue + 1] = { path = e.path,
                    title = e.title or (base_name(e.path):gsub("%.[^%.]+$", "")),
                    kind = "video", at = resume[e.path] }
            end
        end
    end
end

local function all_rows()
    local rows = {}
    for _, r in ipairs(st.continue) do rows[#rows + 1] = r end
    for _, r in ipairs(st.listen) do rows[#rows + 1] = r end
    return rows
end

local function ass_text(s)
    return mp.command_native({ "escape-ass", s })
end

local function shorten(path, n)
    if #path <= n then return path end
    return "…" .. path:sub(#path - n + 2)
end

local function play(row)
    if not row then return end
    st.shown = false
    osd.data = ""
    osd:update()
    mp.commandv("loadfile", row.path, "replace")
end

local function render()
    if not st.shown then return end
    local w, h = window_size()
    local s = h / 720
    osd.res_x, osd.res_y = w, h
    local out = {}
    local function rect(col, x, y, rw, rh)
        out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", col, rect_ass(x, y, rw, rh))
    end
    local function text(x, y, size, col, an, s_text)
        out[#out + 1] = string.format("{\\an%d\\pos(%f,%f)\\fs%f\\1c&H%s&}%s", an, x, y, size, col, s_text)
    end

    rect(COL_BG, 0, 0, w, h)

    -- header
    text(24 * s, 30 * s, 19 * s, COL_FG, 4, "{\\b1}Home")
    st.dots = { x = w - 24 * s - 30 * s, y = 16 * s, w = 30 * s, h = 30 * s }
    local dots = st.dots
    if st.hover == "dots" then rect(COL_HOVER, dots.x, dots.y, dots.w, dots.h) end
    local polys = icons.polys.menu
    if polys then
        out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", COL_FG,
            poly_ass(polys, dots.x + 6 * s, dots.y + 6 * s, 18 / 24 * s))
    end

    local rows = all_rows()
    st.rows = {}
    local y = 80 * s
    local function section(title, list, is_audio, first_index)
        text(24 * s, y, 16 * s, COL_FG, 4, "{\\b1}" .. ass_text(title))
        y = y + 30 * s
        if #list == 0 then
            text(24 * s, y + 14 * s, 14 * s, COL_DIM, 4, "Nothing here yet")
            y = y + 44 * s
            return
        end
        for i, row in ipairs(list) do
            local idx = first_index + i - 1
            local ry = y
            if (st.hover == idx) or (st.sel == idx) then
                rect(COL_HOVER, 16 * s, ry, w - 32 * s, ROW_H * s)
                rect(COL_FG, 16 * s, ry, 2 * s, ROW_H * s) -- white marker: the selection
            end
            local tw, th = (is_audio and 40 or 72) * s, 40 * s
            rect(COL_PANEL, 24 * s, ry + 8 * s, tw, th)
            local tx = 24 * s + tw + 14 * s
            text(tx, ry + 18 * s, 15 * s, COL_FG, 4, ass_text(row.title))
            text(tx, ry + 38 * s, 13 * s, COL_DIM, 4, ass_text(shorten(row.path, 72)))
            if row.at then
                text(w - 24 * s, ry + ROW_H * s / 2, 13 * s, COL_DIM, 6,
                    "Resume at " .. clock(row.at))
            end
            st.rows[#st.rows + 1] = { idx = idx, x0 = 16 * s, x1 = w - 16 * s, y0 = ry, y1 = ry + ROW_H * s }
            y = y + ROW_H * s
        end
        y = y + 12 * s
    end

    section("Continue Watching", st.continue, false, 1)
    section("Listen Again", st.listen, true, #st.continue + 1)

    if #rows == 0 then
        text(24 * s, y + 4 * s, 14 * s, COL_DIM, 4,
            "Play something and it will show up here. Open a file with the menu.")
    end

    osd.data = table.concat(out, "\n")
    osd:update()
end

local function show()
    if st.shown then return end
    load_lists()
    st.shown = true
    st.sel = 1
    st.hover = nil
    mp.add_forced_key_binding("UP", "juxt-home-up", function() move(-1) end, "repeatable")
    mp.add_forced_key_binding("DOWN", "juxt-home-down", function() move(1) end, "repeatable")
    mp.add_forced_key_binding("ENTER", "juxt-home-enter", function() enter() end)
    mp.add_forced_key_binding("MBTN_LEFT", "juxt-home-click", function() click() end)
    render()
end

local function hide()
    if not st.shown then return end
    st.shown = false
    for _, name in ipairs({ "juxt-home-up", "juxt-home-down", "juxt-home-enter", "juxt-home-click" }) do
        mp.remove_key_binding(name)
    end
    osd.data = ""
    osd:update()
end

move = function(step)
    local n = #all_rows()
    if n == 0 then return end
    st.sel = ((st.sel - 1 + step) % n) + 1
    render()
end

local function row_by_index(idx)
    local rows = all_rows()
    return rows[idx]
end

enter = function()
    play(row_by_index(st.sel))
end

click = function()
    local mouse = mp.get_property_native("mouse-pos")
    if not mouse or not st.shown then return end
    local d = st.dots
    if d and mouse.x >= d.x and mouse.x <= d.x + d.w and mouse.y >= d.y and mouse.y <= d.y + d.h then
        mp.commandv("script-message", "juxt-menu-home")
        return
    end
    for _, r in ipairs(st.rows) do
        if mouse.y >= r.y0 and mouse.y < r.y1 and mouse.x >= r.x0 and mouse.x <= r.x1 then
            play(row_by_index(r.idx))
            return
        end
    end
end

mp.observe_property("mouse-pos", "native", function(_, pos)
    if not st.shown or not pos then return end
    local hover
    local d = st.dots
    if d and pos.x >= d.x and pos.x <= d.x + d.w and pos.y >= d.y and pos.y <= d.y + d.h then
        hover = "dots"
    end
    for _, r in ipairs(st.rows) do
        if pos.y >= r.y0 and pos.y < r.y1 and pos.x >= r.x0 and pos.x <= r.x1 then
            hover = r.idx
            st.sel = r.idx
        end
    end
    if hover ~= st.hover then
        st.hover = hover
        render()
    end
end)

mp.observe_property("osd-dimensions", "native", function() if st.shown then render() end end)
mp.observe_property("idle-active", "bool", function(_, idle)
    if idle then show() else hide() end
end)

mp.register_script_message("juxt-home", function() show() end)
mp.register_script_message("juxt-home-refresh", function()
    if st.shown then load_lists() render() end
end)
mp.register_script_message("juxt-home-play-all", function()
    local rows = all_rows()
    if #rows == 0 then return end
    st.shown = false
    osd.data = ""
    osd:update()
    for i, r in ipairs(rows) do
        mp.commandv("loadfile", r.path, i == 1 and "replace" or "append-play")
    end
end)
mp.register_script_message("juxt-home-queue-all", function()
    for _, r in ipairs(all_rows()) do
        mp.commandv("loadfile", r.path, "append")
    end
end)
