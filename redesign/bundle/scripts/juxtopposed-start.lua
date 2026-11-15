-- juxtopposed: show the bar when a file starts, for 10 seconds, then let the OSC hide it as usual
-- (it comes back when the mouse moves). Uses the OSC's osc-visibility message.

local mp = require "mp"

local SHOW_SECONDS = 10
local timer = nil

local function set_visibility(mode)
    mp.command("script-message-to osc osc-visibility " .. mode)
end

mp.register_event("file-loaded", function()
    if timer then timer:kill() end
    set_visibility("always")
    timer = mp.add_timeout(SHOW_SECONDS, function()
        timer = nil
        set_visibility("auto")
    end)
end)
