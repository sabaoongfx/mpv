-- juxtopposed: the three-dot menus (player and Home), drawn as VLC-style cards.
--
-- Messages (set by the bundled osc.conf):
--   juxt-menu       open the player menu (menu button in the bar)
--   juxt-menu-home  open the Home menu (three dots on the Home view)
--
-- Keys while open: Up/Down move, Enter runs, Right or Enter opens a submenu, Left or Esc goes back,
-- Esc on the top level closes. Mouse: hover highlights, click runs, click outside closes.
-- Only commands mpv has are listed here; see redesign/PLAN.md, phase 3.

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

local ROW_H, PAD, CARD_W, SEP_H = 32, 4, 260, 9 -- px at a 720 px high window (scaled below)
local COL_BG = "181818"
local COL_HOVER = "242424" -- selected row; 1.01:1 with #191919 was invisible (WCAG 2.4.7)
local COL_LINE = "373737"
local COL_FG = "E3E3E3"
local COL_DIM = "8F8F8F"

-- Menu content. `cmd` is an mpv command (';' separates commands); `sub` opens a submenu.
local menus = {}
menus.player = {
    { label = "Play / Pause", icon = "m_play", cmd = "cycle pause" },
    { label = "Stop", icon = "m_stop", cmd = "stop" },
    { sep = true },
    { label = "Previous Item", icon = "m_previous", cmd = "playlist-prev" },
    { label = "Next Item", icon = "m_next", cmd = "playlist-next" },
    { sep = true },
    { label = "Playback", icon = "m_playback", sub = {
        { label = "Slower", cmd = "add speed -0.25" },
        { label = "Normal speed", cmd = "set speed 1" },
        { label = "Faster", cmd = "add speed 0.25" },
    } },
    { label = "Video", icon = "m_video", sub = {
        { label = "Fullscreen", cmd = "cycle fullscreen" },
        { label = "Screenshot", cmd = "screenshot" },
        { label = "Deinterlace", cmd = "cycle deinterlace" },
    } },
    { label = "Audio", icon = "m_audio", sub = {
        { label = "Mute", cmd = "cycle mute" },
        { label = "Next audio track", cmd = "cycle audio" },
    } },
    { label = "Subtitle", icon = "m_subtitle", sub = {
        { label = "Next subtitle track", cmd = "cycle sub" },
        { label = "Show / hide subtitles", cmd = "cycle sub-visibility" },
    } },
    { sep = true },
    { label = "More Settings", icon = "m_moresettings", cmd = "script-binding select/menu" },
    { sep = true },
    { label = "Quit", icon = "m_quit", cmd = "quit" },
}
menus.home = {
    { label = "Open File(s)", icon = "m_file", cmd = "script-message juxt-open-files" },
    { label = "Open Folder", icon = "m_folder", cmd = "script-message juxt-open-folder" },
    { label = "Open from Clipboard", icon = "m_openmedia",
      cmd = "update-clipboard text; loadfile ${clipboard/text}" },
    { sep = true },
    { label = "Play all", icon = "m_play", cmd = "script-message juxt-home-play-all" },
    { label = "Add all to queue", icon = "m_queue", cmd = "script-message juxt-home-queue-all" },
    { sep = true },
    { label = "Rescan library", icon = "m_resync", cmd = "script-message juxt-home-refresh" },
    { label = "Library settings", icon = "m_settings", cmd = "script-binding select/edit-config-file" },
}

local osd = mp.create_osd_overlay("ass-events")
osd.z = 60

local st = { stack = {}, hover = nil, rows = nil, card = nil }
local move, activate, back, click -- defined below; used by the key bindings
local KEYS = { "juxt-menu-up", "juxt-menu-down", "juxt-menu-enter", "juxt-menu-right",
               "juxt-menu-left", "juxt-menu-esc", "juxt-menu-click" }

-- ASS helpers. Drawings use \p4 (1 unit = 1/8 px), so every coordinate is multiplied by 8.
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

local function run(cmd)
    for piece in string.gmatch(cmd .. ";", "(.-);") do
        local c = piece:match("^%s*(.-)%s*$")
        if c ~= "" then mp.command(c) end
    end
end

-- Open the desktop's file chooser (xdg portal, via bin/juxt-pick-file.py) and play what is chosen.
-- It runs asynchronously, so mpv keeps running while the dialog is open.
local function pick(mode, cb)
    local helper = mp.find_config_file("bin/juxt-pick-file.py")
    if not helper then
        mp.osd_message("File chooser helper not found (install bin/juxt-pick-file.py)")
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = { "python3", helper, mode },
        capture_stdout = true,
        playback_only = false,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then return end
        local paths = {}
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do paths[#paths + 1] = line end
        if #paths > 0 then cb(paths) end
    end)
end

mp.register_script_message("juxt-open-files", function()
    pick("file", function(paths)
        for i, p in ipairs(paths) do
            mp.commandv("loadfile", p, i == 1 and "replace" or "append-play")
        end
    end)
end)
-- mpv cannot play a folder, so the media files in it are queued, in name order (as VLC does)
local MEDIA_EXT = { mkv = true, mp4 = true, avi = true, mov = true, webm = true, m4v = true, ts = true,
    mpg = true, mpeg = true, wmv = true, flv = true, ogv = true, vob = true,
    flac = true, mp3 = true, ogg = true, oga = true, opus = true, m4a = true, wav = true, aac = true,
    wma = true, aiff = true, ape = true }

local function folder_media(dir)
    local files = {}
    local listing = utils.readdir(dir, "files") or {}
    for _, name in ipairs(listing) do
        local ext = name:match("%.([^%.]+)$")
        if ext and MEDIA_EXT[ext:lower()] then files[#files + 1] = utils.join_path(dir, name) end
    end
    table.sort(files)
    return files
end

mp.register_script_message("juxt-open-folder", function()
    pick("folder", function(paths)
        local files = folder_media(paths[1])
        if #files == 0 then
            mp.osd_message("No media files in that folder")
            return
        end
        for i, f in ipairs(files) do
            mp.commandv("loadfile", f, i == 1 and "replace" or "append-play")
        end
    end)
end)

local function top() return st.stack[#st.stack] end

local function selectable(it) return not (it.sep or it.header) end

local function first_selectable(items)
    for i, it in ipairs(items) do if selectable(it) then return i end end
    return 1
end

local function close()
    st.stack = {}
    st.hover = nil
    st.rows = nil
    for _, name in ipairs(KEYS) do mp.remove_key_binding(name) end
    osd.data = ""
    osd:update()
end

local function layout()
    local t = top()
    local w, h = window_size()
    local s = h / 720
    local card_w = (st.width or CARD_W) * s
    local pad = PAD * s
    local row_h = ROW_H * s
    local sep_h = SEP_H * s
    local card_h = 2 * pad
    for _, it in ipairs(t.items) do
        card_h = card_h + (it.sep and sep_h or row_h)
    end
    -- the player menu opens under its button in the top strip (top left); the Home menu under the
    -- three dots (top right)
    local x = 10 * s
    if st.anchor == "top-right" then x = w - card_w - 10 * s end
    local y = 44 * s
    if st.anchor == "bottom" or st.anchor == "bottom-right" then y = math.max(0, h - 44 * s - 8 * s - card_h) end
    if st.anchor == "bottom-right" then x = w - card_w - 16 * s end
    local rows, cy = {}, y + pad
    for i, it in ipairs(t.items) do
        local rh = it.sep and sep_h or row_h
        rows[i] = { y0 = cy, y1 = cy + rh, sep = it.sep, header = it.header }
        cy = cy + rh
    end
    return { x = x, y = y, w = card_w, h = card_h, pad = pad, row_h = row_h, s = s, rows = rows }
end

local function render()
    if #st.stack == 0 then return end
    local w, h = window_size()
    osd.res_x, osd.res_y = w, h
    local t = top()
    local L = layout()
    st.rows, st.card = L.rows, L
    local out = {}

    -- card
    out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\3c&H%s&\\bord%.2f\\shad0\\p4}%s{\\p0}",
        COL_BG, COL_LINE, math.max(1, L.s), rect_ass(L.x, L.y, L.w, L.h))

    for i, it in ipairs(t.items) do
        local r = L.rows[i]
        local ry = r.y0
        if it.sep then
            out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", COL_LINE,
                rect_ass(L.x + 12 * L.s, ry + 4 * L.s, L.w - 24 * L.s, math.max(1, L.s)))
        elseif it.header then
            out[#out + 1] = string.format("{\\an4\\pos(%f,%f)\\fs%f\\1c&H%s&}%s",
                L.x + 12 * L.s, ry + L.row_h / 2, 12 * L.s, COL_DIM, it.label)
        else
            local cy = ry + L.row_h / 2
            if st.hover == i then
                out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", COL_HOVER,
                    rect_ass(L.x + L.pad, ry, L.w - 2 * L.pad, L.row_h))
                -- white marker on the left edge: the selection shows without relying on the fill
                out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", COL_FG,
                    rect_ass(L.x + L.pad, ry, 2 * L.s, L.row_h))
            end
            local polys = it.icon and icons.polys[it.icon]
            if polys then
                -- icons are 24 px boxes; drawn at 20 px, centred on the row
                local k = 20 / 24 * L.s
                out[#out + 1] = string.format("{\\an7\\pos(0,0)\\1c&H%s&\\p4}%s{\\p0}", COL_FG,
                    poly_ass(polys, L.x + 12 * L.s, cy - 10 * L.s, k))
            end
            out[#out + 1] = string.format("{\\an4\\pos(%f,%f)\\fs%f\\1c&H%s&}%s",
                L.x + 42 * L.s, cy, 14 * L.s, COL_FG, it.label)
            if it.sub then
                out[#out + 1] = string.format("{\\an6\\pos(%f,%f)\\fs%f\\1c&H%s&}›",
                    L.x + L.w - 12 * L.s, cy, 16 * L.s, COL_DIM)
            end
            if it.checked then
                out[#out + 1] = string.format("{\\an6\\pos(%f,%f)\\fs%f\\1c&H%s&}✓",
                    L.x + L.w - 14 * L.s, cy, 15 * L.s, COL_FG)
            end
        end
    end
    osd.data = table.concat(out, "\n")
    osd:update()
end

local anchors = { player = "top-left", home = "top-right" }

-- Open a menu with the given items (and the anchor it opens at).
local function open_items(items, anchor, width)
    st.anchor = anchor or "top-left"
    st.width = width
    st.stack = { { items = items, sel = 0 } }
    local t = top()
    t.sel = first_selectable(t.items)
    st.hover = t.sel -- show the keyboard selection straight away
    mp.add_forced_key_binding("UP", "juxt-menu-up", function() move(-1) end, "repeatable")
    mp.add_forced_key_binding("DOWN", "juxt-menu-down", function() move(1) end, "repeatable")
    mp.add_forced_key_binding("ENTER", "juxt-menu-enter", function() activate(top().sel) end)
    mp.add_forced_key_binding("RIGHT", "juxt-menu-right", function() activate(top().sel) end)
    mp.add_forced_key_binding("LEFT", "juxt-menu-left", back)
    mp.add_forced_key_binding("ESC", "juxt-menu-esc", back)
    mp.add_forced_key_binding("MBTN_LEFT", "juxt-menu-click", click)
    render()
end

local function open(name)
    open_items(menus[name], anchors[name])
end

-- The audio and subtitle popups (as in the VLC design): tracks with a check on the current one,
-- then the output devices (audio) or Add subtitles (subtitles). Built from mpv's lists each time.
local function track_list(kind)
    local out = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == kind then out[#out + 1] = t end
    end
    return out
end

local function track_label(t)
    local name = t.title or t.lang or ("track " .. t.id)
    if t.lang and t.title then name = t.title .. " [" .. t.lang .. "]" end
    return name
end

-- Long names are cut to fit the card (about 7 px per character at 14 px text).
local function fit(text, max_chars)
    -- braces and backslashes would be read as ASS tags
    text = tostring(text or ""):gsub("[{}\\]", "")
    if #text <= max_chars then return text end
    return text:sub(1, max_chars - 3) .. "..."
end

-- The popups must fit above the bar: at most this many rows (height of the window minus the bar).
local function max_popup_rows()
    local _, h = window_size()
    local s = h / 720
    local room = h - 44 * s - 16 * s - 44 * s -- bar, gaps, and the top strip
    return math.max(4, math.floor((room - 2 * PAD * s) / (ROW_H * s)))
end

-- Keeps the current item in a capped list: the first (max - 1) items, plus the current one.
local function cap_list(items, current_index, max)
    if #items <= max then return items end
    local out = {}
    for i = 1, max - 1 do out[i] = items[i] end
    if current_index > max - 1 then out[max] = items[current_index] else out[max] = items[max] end
    return out
end

local function audio_items()
    local items = { { header = true, label = "Audio track" } }
    for _, t in ipairs(track_list("audio")) do
        local id = t.id
        items[#items + 1] = { label = fit(track_label(t), 40), checked = t.selected,
            fn = function() mp.set_property_number("aid", id) end }
    end
    if #items == 1 then items[#items + 1] = { label = "No audio tracks", fn = function() end } end
    items[#items + 1] = { header = true, label = "Output device" }
    local current = mp.get_property("audio-device")
    local devices = {}
    local current_index = 0
    for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
        local name = d.name
        devices[#devices + 1] = { label = fit(d.description or name, 40), checked = name == current,
            fn = function() mp.set_property("audio-device", name) end }
        if name == current then current_index = #devices end
    end
    -- the header row and the track rows come first; the device list fills the rest
    local room = max_popup_rows() - #items
    for _, d in ipairs(cap_list(devices, current_index, math.max(1, room))) do items[#items + 1] = d end
    return items
end

local function subs_items()
    local items = { { header = true, label = "Subtitle track" } }
    local off = mp.get_property("sid") == "no" or mp.get_property("sid") == nil
    items[#items + 1] = { label = "Off", checked = off, fn = function() mp.set_property("sid", "no") end }
    for _, t in ipairs(track_list("sub")) do
        local id = t.id
        items[#items + 1] = { label = fit(track_label(t), 40), checked = t.selected,
            fn = function() mp.set_property_number("sid", id) end }
    end
    items[#items + 1] = { sep = true }
    items[#items + 1] = { label = "Add subtitles…", icon = "m_file",
        fn = function()
            pick("file", function(paths)
                for _, p in ipairs(paths) do mp.commandv("sub-add", p, "select") end
            end)
        end }
    return items
end

mp.register_script_message("juxt-menu-audio", function()
    if #st.stack > 0 then return close() end
    open_items(audio_items(), "bottom-right", 320)
end)
mp.register_script_message("juxt-menu-subs", function()
    if #st.stack > 0 then return close() end
    open_items(subs_items(), "bottom-right", 320)
end)

move = function(step)
    local t = top()
    if not t then return end
    local n = #t.items
    local i = t.sel
    for _ = 1, n do
        i = ((i - 1 + step) % n) + 1
        if selectable(t.items[i]) then break end
    end
    t.sel = i
    st.hover = i
    render()
end

activate = function(i)
    local t = top()
    if not t then return end
    local it = t.items[i]
    if not it or not selectable(it) then return end
    if it.sub then
        st.stack[#st.stack + 1] = { items = it.sub, sel = first_selectable(it.sub) }
        render()
    elseif it.fn then
        close()
        it.fn()
    else
        close()
        run(it.cmd)
    end
end

back = function()
    st.stack[#st.stack] = nil
    if #st.stack == 0 then close() else render() end
end

click = function()
    local L = st.card
    local mouse = mp.get_property_native("mouse-pos")
    if not L or not mouse then return close() end
    local mx, my = mouse.x, mouse.y
    if mx < L.x or mx > L.x + L.w or my < L.y or my > L.y + L.h then
        return close()
    end
    for i, r in ipairs(L.rows) do
        if not r.sep and not r.header and my >= r.y0 and my < r.y1 then
            return activate(i)
        end
    end
end

mp.observe_property("mouse-pos", "native", function(_, pos)
    if #st.stack == 0 or not st.card or not pos then return end
    local hover
    for i, r in ipairs(st.card.rows) do
        if not r.sep and not r.header and pos.y >= r.y0 and pos.y < r.y1 and pos.x >= st.card.x and pos.x <= st.card.x + st.card.w then
            hover = i
        end
    end
    if hover ~= st.hover then
        st.hover = hover
        if hover then top().sel = hover end
        render()
    end
end)

mp.observe_property("osd-dimensions", "native", function() if #st.stack > 0 then render() end end)

local function toggle(name)
    return function()
        if #st.stack > 0 then close() else open(name) end
    end
end
mp.register_script_message("juxt-menu", toggle("player"))
mp.register_script_message("juxt-menu-home", toggle("home"))
