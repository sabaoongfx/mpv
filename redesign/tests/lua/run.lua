-- Runs the juxtopposed Lua tests with plain Lua 5.x (no extra packages).
--   JUXT_TEST_DIR=<this folder> lua run.lua
-- Exit status 0 when every test passes.

local dir = os.getenv("JUXT_TEST_DIR") or (arg and arg[0] and arg[0]:match("^(.*)/[^/]+$")) or "."
_G.JUXT_TEST_DIR = dir
package.path = dir .. "/?.lua;" .. package.path

local files = { "test_icons", "test_menu", "test_home" }
local passed, failed = 0, 0
for _, name in ipairs(files) do
    local tests = dofile(dir .. "/" .. name .. ".lua")
    for _, t in ipairs(tests) do
        local ok, err = pcall(t[2])
        if ok then
            passed = passed + 1
            print("ok    " .. name .. ": " .. t[1])
        else
            failed = failed + 1
            print("FAIL  " .. name .. ": " .. t[1] .. "\n      " .. tostring(err))
        end
    end
end
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
