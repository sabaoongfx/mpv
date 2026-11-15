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

local st = { thumb = {}, shown = false, sel = 1, hover = nil, rows = {}, dots = nil, continue = {}, listen = {} }
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

-- Thumbnail colours, as in the prototype: a gradient from hsl(hue, 30%, 22%) to hsl(hue, 22%, 10%),
-- where the hue comes from the file name. mpv has no frame previews here, so the gradient stands in.
local function hsl_rgb(h, sat, l)
    local c = (1 - math.abs(2 * l - 1)) * sat
    local hp = (h / 60) % 6
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b = 0, 0, 0
    if hp < 1 then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    local m = l - c / 2
    return (r + m) * 255, (g + m) * 255, (b + m) * 255
end

local function thumb_colours(path)
    local hue = 0
    for i = 1, #path do hue = (hue * 31 + path:byte(i)) % 360 end
    local r1, g1, b1 = hsl_rgb(hue, 0.30, 0.22)
    local r2, g2, b2 = hsl_rgb(hue, 0.22, 0.10)
    return { r1, g1, b1 }, { r2, g2, b2 }
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

-- Video thumbnails, as in VLC: a frame at 15% of the video, made with ffmpeg and cached as raw BGRA.
-- They are drawn with overlay-add (ids 40..63). Audio rows keep the gradient.
local THUMB_W, THUMB_H = 144, 80
local OV_FIRST, OV_LAST = 40, 63
local THUMB_VF = "scale=144:80:force_original_aspect_ratio=decrease,pad=144:80:(ow-iw)/2:(oh-ih)/2:color=black"
st.overlays_on = {}   -- id -> true while drawn
st.overlay_key = ""   -- what was last drawn, so an unchanged Home is not re-sent

local function thumb_dir()
    local base = os.getenv("XDG_CACHE_HOME")
    if not base or base == "" then base = (os.getenv("HOME") or ".") .. "/.cache" end
    return base .. "/mpv-juxtopposed/thumbs"
end

local function thumb_file(path)
    local h1, h2 = 5381, 0
    for i = 1, #path do
        local c = path:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c) % 4294967296
    end
    return string.format("%s/%08x%08x.bgra", thumb_dir(), h1, h2)
end

local function file_size(name)
    local f = io.open(name, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- st.thumb[path]: "pending", "ready" (file on disk) or "none" (no frame; the gradient stays)
local function request_thumb(path)
    if st.thumb[path] then return end
    local file = thumb_file(path)
    if file_size(file) == THUMB_W * THUMB_H * 4 then
        st.thumb[path] = "ready"
        return
    end
    st.thumb[path] = "pending"
    local function done(state)
        st.thumb[path] = state
        if st.shown and st.redraw then st.redraw() end
    end
    mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
        args = { "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path } },
        function(ok, res)
            local dur = ok and res and res.status == 0 and tonumber((res.stdout or ""):match("%d+%.?%d*"))
            if not dur or dur <= 0 then return done("none") end
            mp.command_native_async({ name = "subprocess", capture_stdout = true, playback_only = false,
                args = { "ffmpeg", "-v", "error", "-ss", string.format("%.3f", dur * 0.15), "-i", path,
                    "-frames:v", "1", "-vf", THUMB_VF, "-f", "rawvideo", "-pix_fmt", "bgra", "-" } },
                function(ok2, res2)
                    local data = res2 and res2.stdout
                    if not ok2 or not data or res2.status ~= 0 or #data ~= THUMB_W * THUMB_H * 4 then
                        return done("none")
                    end
                    mp.command_native({ name = "subprocess", args = { "mkdir", "-p", thumb_dir() },
                        playback_only = false })
                    local out = io.open(file, "wb")
                    if not out then return done("none") end
                    out:write(data)
                    out:close()
                    done("ready")
                end)
        end)
end

-- Draw the thumbnails placed this frame and remove the ones no longer shown.
local function sync_overlays(placed)
    local keys = {}
    for _, p in ipairs(placed) do
        keys[#keys + 1] = string.format("%d:%d:%d:%d:%d", p.id, p.x, p.y, p.w, p.h)
    end
    local key = table.concat(keys, "|")
    if key == st.overlay_key then return end
    st.overlay_key = key
    local now = {}
    for _, p in ipairs(placed) do
        now[p.id] = true
        mp.commandv("overlay-add", tostring(p.id), tostring(p.x), tostring(p.y),
            thumb_file(p.path), "0", "bgra", tostring(THUMB_W), tostring(THUMB_H), tostring(THUMB_W * 4),
            tostring(p.w), tostring(p.h))
    end
    for id in pairs(st.overlays_on) do
        if not now[id] then mp.commandv("overlay-remove", tostring(id)) end
    end
    st.overlays_on = now
end

local function clear_overlays()
    -- remove every thumbnail drawn (sync_overlays skips unchanged frames, so it cannot be used here)
    for id in pairs(st.overlays_on) do mp.commandv("overlay-remove", tostring(id)) end
    st.overlays_on = {}
    st.overlay_key = ""
end

local function render()
    if not st.shown then return end
    local w, h = window_size()
    local s = h / 720
    osd.res_x, osd.res_y = w, h
    local out = {}
    local placed = {} -- thumbnails drawn this frame (see sync_overlays)
    local function rect(col, x, y, rw, rh)
        out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", col, rect_ass(x, y, rw, rh))
    end
    local function text(x, y, size, col, an, s_text)
        out[#out + 1] = string.format("{\\an%d\\pos(%f,%f)\\fs%f\\1c&H%s&}%s", an, x, y, size, col, s_text)
    end

    rect(COL_BG, 0, 0, w, h)

    -- header
    text(24 * s, 30 * s, 26 * s, COL_FG, 4, "{\\b1}Home")
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
        text(24 * s, y, 24 * s, COL_FG, 4, "{\\b1}" .. ass_text(title))
        y = y + 36 * s
        if #list == 0 then
            text(24 * s, y + 14 * s, 20 * s, COL_DIM, 4, "Nothing here yet")
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
            if not is_audio and row.path then
                request_thumb(row.path)
                if st.thumb[row.path] == "ready" and placed and #placed < (OV_LAST - OV_FIRST + 1) then
                    placed[#placed + 1] = { id = OV_FIRST + #placed, path = row.path,
                        x = math.floor(24 * s), y = math.floor(ry + 8 * s),
                        w = math.floor(tw), h = math.floor(th) }
                end
            end
            -- gradient (under the thumbnail, and the fallback for audio and files without a frame): from the top colour to the bottom colour (BGR for ASS)
            local c1, c2 = thumb_colours(row.path)
            -- two halves: the top in the gradient's first colour, the bottom in its second
            local function hex(c) return string.format("%02X%02X%02X", math.floor(c[3] + 0.5), math.floor(c[2] + 0.5), math.floor(c[1] + 0.5)) end
            local half = th / 2
            rect(hex(c1), 24 * s, ry + 8 * s, tw, half + 1) -- +1: no seam between the halves
            rect(hex(c2), 24 * s, ry + 8 * s + half, tw, half)
            local tx = 24 * s + tw + 14 * s
            text(tx, ry + 18 * s, 22 * s, COL_FG, 4, ass_text(row.title))
            text(tx, ry + 38 * s, 18 * s, COL_DIM, 4, ass_text(shorten(row.path, 72)))
            if row.at then
                text(w - 24 * s, ry + ROW_H * s / 2, 18 * s, COL_DIM, 6,
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
        text(24 * s, y + 4 * s, 20 * s, COL_DIM, 4,
            "Play something and it will show up here. Open a file with the menu.")
    end

    sync_overlays(placed)
    osd.data = table.concat(out, "\n")
    osd:update()
end

st.redraw = function() if st.shown then render() end end

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
    clear_overlays()
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
-- the window title says Home while Home shows, and goes back to the usual title when a file plays
local title_option = mp.get_property("options/title")
mp.observe_property("idle-active", "bool", function(_, idle)
    if idle then
        show()
        -- the option, not the property: mpv rewrites the title when it stops, which would undo a property
        mp.set_property("options/title", "Home")
    else
        hide()
        -- set the option (the template), so mpv expands it again with the file's name
        if title_option then mp.set_property("options/title", title_option) end
    end
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
