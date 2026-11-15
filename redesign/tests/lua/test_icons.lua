-- Tests for the generated icon data (redesign/bundle/scripts/juxtopposed-icons.lua).

local HERE = _G.JUXT_TEST_DIR or os.getenv("JUXT_TEST_DIR") or "."
local SCRIPT_DIR = HERE .. "/../../bundle/scripts"

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("a")
    f:close()
    return s
end

local tests = {}

tests[#tests + 1] = { "every polygon is an even list of finite numbers inside the 24 px box", function()
    local M = dofile(SCRIPT_DIR .. "/juxtopposed-icons.lua")
    local count = 0
    for name, polys in pairs(M.polys) do
        for _, p in ipairs(polys) do
            assert(#p >= 6 and #p % 2 == 0, name .. ": polygon needs an even count of at least 3 points")
            for i = 1, #p do
                local v = p[i]
                assert(type(v) == "number" and v == v and math.abs(v) < 1e6, name .. ": bad number " .. tostring(v))
                assert(v >= -1 and v <= 25, name .. ": coordinate " .. v .. " outside the 24 px box")
            end
            count = count + 1
        end
    end
    assert(count > 0, "no polygons at all")
end }

tests[#tests + 1] = { "the cone track and fill are inside the 91 x 30 box", function()
    local M = dofile(SCRIPT_DIR .. "/juxtopposed-icons.lua")
    for _, part in ipairs({ "track", "fill" }) do
        assert(#M.cone[part] > 0, part .. " missing")
        for _, p in ipairs(M.cone[part]) do
            for i = 1, #p, 2 do
                assert(p[i] >= 0 and p[i] <= 91 and p[i + 1] >= 0 and p[i + 1] <= 30, part .. " outside the box")
            end
        end
    end
end }

tests[#tests + 1] = { "every icon name used by the menu and Home scripts exists in the icon data", function()
    local M = dofile(SCRIPT_DIR .. "/juxtopposed-icons.lua")
    for _, script in ipairs({ "juxtopposed-menu.lua", "juxtopposed-home.lua" }) do
        local src = read(SCRIPT_DIR .. "/" .. script)
        for name in src:gmatch('icon%s*=%s*"([%w_]+)"') do
            assert(M.polys[name], script .. " uses missing icon " .. name)
        end
        for name in src:gmatch('icons%.polys%.([%w_]+)') do
            assert(M.polys[name], script .. " uses missing icon " .. name)
        end
    end
end }

return tests
