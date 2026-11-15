-- A small stand-in for mpv's Lua API (mp and mp.utils), for the juxtopposed scripts.
-- It records what the script asks mpv to do, and lets a test fire the callbacks the script
-- registered (script messages, key bindings, property observers).

local M = {}

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Minimal JSON object decoder: flat objects with string, number, boolean or null values
-- (no escapes). Enough for the watch history lines, one object per line.
local function parse_json(text)
    local body = text:match("^%s*{(.*)}%s*$")
    if not body then return nil, "not an object" end
    local obj, pos = {}, 1
    while true do
        local _, ke, key = body:find('^%s*"([^"]*)"%s*:%s*', pos)
        if not key then break end
        pos = ke + 1
        local val
        if body:sub(pos, pos) == '"' then
            local ve = body:find('"', pos + 1, true)
            if not ve then return nil, "unterminated string" end
            val = body:sub(pos + 1, ve - 1)
            pos = ve + 1
        else
            local ve = body:find(",", pos, true) or (#body + 1)
            local raw = body:sub(pos, ve - 1):match("^%s*(.-)%s*$")
            pos = ve
            if raw == "true" then val = true
            elseif raw == "false" then val = false
            elseif raw == "null" then val = nil
            else val = tonumber(raw) end
        end
        obj[key] = val
        local _, ce = body:find("^%s*,", pos)
        if not ce then break end
        pos = ce + 1
    end
    return obj
end

-- Build a fresh fake mp. `opts`:
--   dir      directory the script lives in (mp.get_script_directory)
--   props    table of property values (strings, numbers, or tables for native properties)
--   state    directory that stands in for ~~state/
--   ls_ok    whether zenity or kdialog are "installed" (for the file dialogs)
function M.new(opts)
    opts = opts or {}
    local mp = {
        commands = {},      -- strings from mp.command, and "cmd|arg|..." for mp.commandv
        osd_messages = {},
        handlers = {},      -- script messages
        keys = {},          -- forced key bindings by name
        observers = {},     -- property observers by name
        props = opts.props or {},
    }
    mp.props["osd-dimensions"] = mp.props["osd-dimensions"] or { w = 1280, h = 720 }

    mp.overlay = { data = "", updates = 0 }
    function mp.overlay:update() self.updates = self.updates + 1 end

    local api = {}
    function api.create_osd_overlay() return mp.overlay end
    function api.get_script_directory() return opts.dir end
    -- mp.find_config_file: the scripts look for their icon data in the config folder as a fallback
    function api.find_config_file(name) return (opts.config or "/fake/config") .. "/" .. name end
    function api.get_property(name)
        local v = mp.props[name]
        if v == nil then return nil end
        return tostring(v)
    end
    function api.get_property_native(name) return mp.props[name] end
    function api.add_periodic_timer(interval, fn) return { kill = function() end } end
    function api.set_property(name, value) mp.props[name] = value; mp.set_log = mp.set_log or {}; table.insert(mp.set_log, name .. "=" .. tostring(value)) end
    -- mpv runs `script-message name` by calling the script's handler for that name
    local function dispatch(name)
        local fn = mp.handlers[name]
        if fn then fn() end
    end
    function api.command(cmd)
        table.insert(mp.commands, cmd)
        local name = cmd:match("^script%-message%s+(%S+)")
        if name then dispatch(name) end
    end
    function api.commandv(...)
        local args = { ... }
        table.insert(mp.commands, table.concat(args, "|"))
        if args[1] == "script-message" then dispatch(args[2]) end
    end
    function api.command_native(args)
        if args[1] == "expand-path" then
            local p = args[2]
            if opts.state then p = p:gsub("^~~state", opts.state) end
            return p
        elseif args[1] == "escape-ass" then
            return (args[2]:gsub("([{}\\])", "\\%1"))
        end
        return nil
    end
    function api.osd_message(text) table.insert(mp.osd_messages, text) end
    -- async subprocess: record the call; the test can supply a result through opts.pick_stdout
    mp.async_calls = {}
    function api.command_native_async(args, cb)
        table.insert(mp.async_calls, args)
        local stdout = opts.pick_stdout or ""
        cb(true, { status = opts.pick_status or 0, stdout = stdout })
    end
    function api.register_script_message(name, fn) mp.handlers[name] = fn end
    function api.observe_property(name, _, fn) mp.observers[name] = fn end
    function api.add_forced_key_binding(_, name, fn) mp.keys[name] = fn end
    function api.remove_key_binding(name) mp.keys[name] = nil end

    -- mp.utils
    local utils = {}
    function utils.parse_json(text) return parse_json(text) end
    function utils.readdir(dir, _)
        local names = {}
        local p = io.popen("ls -1 " .. shell_quote(dir) .. " 2>/dev/null")
        if not p then return nil end
        for line in p:lines() do names[#names + 1] = line end
        p:close()
        return names
    end
    function utils.subprocess(args)
        -- `which x` succeeds only for the tools the test says are installed
        if args.args[1] == "which" then
            local tool = args.args[2]
            local ok = opts.tools and opts.tools[tool]
            return { status = ok and 0 or 1 }
        end
        return { status = 1, stdout = "" }
    end

    for k, v in pairs(api) do mp[k] = v end
    mp.utils = utils
    return mp
end

-- Load one script with this fake mp. Returns the fake mp (its handlers and state are filled in).
function M.load(script_path, opts)
    local fake = M.new(opts)
    package.loaded["mp"] = fake
    package.loaded["mp.utils"] = fake.utils
    dofile(script_path)
    return fake
end

-- Fire a registered script message.
function M.message(fake, name, ...)
    local fn = fake.handlers[name]
    assert(fn, "no script message handler named " .. name)
    fn(...)
end

-- Press a forced key binding by its name.
function M.key(fake, name)
    local fn = fake.keys[name]
    assert(fn, "no forced key binding named " .. name)
    fn()
end

-- Send a property change to an observer.
function M.observe(fake, name, value)
    local fn = fake.observers[name]
    assert(fn, "no observer for " .. name)
    fn(name, value)
end

return M
