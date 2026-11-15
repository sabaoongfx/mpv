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

-- Open a file dialog through zenity or kdialog (mpv has no native dialog). Calls back with paths.
local function pick(folder, cb)
    local tries = folder
        and { { "zenity", "--file-selection", "--directory" }, { "kdialog", "--getexistingdirectory", "." } }
        or { { "zenity", "--file-selection", "--multiple", "--separator=\n" }, { "kdialog", "--getopenfilename", "." } }
    for _, args in ipairs(tries) do
        local probe = utils.subprocess({ args = { "which", args[1] }, playback_only = false })
        if probe.status == 0 then
            local res = utils.subprocess({ args = args, playback_only = false })
            if res.status == 0 and res.stdout then
                local paths = {}
                for line in res.stdout:gmatch("[^\r\n]+") do paths[#paths + 1] = line end
                cb(paths)
            end
            return
        end
    end
    mp.osd_message("No file dialog found: install zenity or kdialog")
end

mp.register_script_message("juxt-open-files", function()
    pick(false, function(paths)
        for i, p in ipairs(paths) do
            mp.commandv("loadfile", p, i == 1 and "replace" or "append-play")
        end
    end)
end)
mp.register_script_message("juxt-open-folder", function()
    pick(true, function(paths)
        if paths[1] then mp.commandv("loadfile", paths[1], "replace") end
    end)
end)

local function top() return st.stack[#st.stack] end

local function first_selectable(items)
    for i, it in ipairs(items) do if not it.sep then return i end end
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
    local card_w = CARD_W * s
    local pad = PAD * s
    local row_h = ROW_H * s
    local sep_h = SEP_H * s
    local card_h = 2 * pad
    for _, it in ipairs(t.items) do
        card_h = card_h + (it.sep and sep_h or row_h)
    end
    local x = 10 * s
    local bottom = h - 56 * s - 8 * s -- above the bottom bar
    local y = math.max(0, bottom - card_h)
    local rows, cy = {}, y + pad
    for i, it in ipairs(t.items) do
        local rh = it.sep and sep_h or row_h
        rows[i] = { y0 = cy, y1 = cy + rh, sep = it.sep }
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
        end
    end
    osd.data = table.concat(out, "\n")
    osd:update()
end

local function open(name)
    st.stack = { { items = menus[name], sel = 0 } }
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

move = function(step)
    local t = top()
    if not t then return end
    local n = #t.items
    local i = t.sel
    for _ = 1, n do
        i = ((i - 1 + step) % n) + 1
        if not t.items[i].sep then break end
    end
    t.sel = i
    st.hover = i
    render()
end

activate = function(i)
    local t = top()
    if not t then return end
    local it = t.items[i]
    if not it or it.sep then return end
    if it.sub then
        st.stack[#st.stack + 1] = { items = it.sub, sel = first_selectable(it.sub) }
        render()
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
        if not r.sep and my >= r.y0 and my < r.y1 then
            return activate(i)
        end
    end
end

mp.observe_property("mouse-pos", "native", function(_, pos)
    if #st.stack == 0 or not st.card or not pos then return end
    local hover
    for i, r in ipairs(st.card.rows) do
        if not r.sep and pos.y >= r.y0 and pos.y < r.y1 and pos.x >= st.card.x and pos.x <= st.card.x + st.card.w then
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
