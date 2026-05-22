--[[
    LuatOS unit-test runner.

    Run via the PC simulator:
        ./tools/luatos_pc/V2031/luatos-pc.exe ./test/ ./src/

    The first arg is the project directory (contains main.lua). Subsequent
    args are added to package.path so `require("provisioning")` finds
    src/provisioning.lua.

    On success the log contains the line: `UNITTEST_RESULT PASS`.
    On any failure: `UNITTEST_RESULT FAIL`. CI greps for these.
    Exits with code 0 (pass) or 1 (fail) via os.exit on the PC simulator.
]]

PROJECT = "nemopi-tests"
VERSION = "0.0.0"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- Replace the LuatOS network/storage globals with in-process fakes BEFORE
-- requiring any module under test. The fakes implement the same surface
-- the production code touches; their state resets between tests.
_G.http = require("fake_http")
_G.fskv = require("fake_fskv")

-- Polling code uses sys.wait; we want tests to finish instantly. Stub it
-- to a zero-timeout yield so the cooperative scheduler still ticks (in case
-- code under test ever relies on other tasks making progress between waits)
-- but no real time elapses.
local real_sys_wait = sys.wait
sys.wait = function() real_sys_wait(0) end

sys.taskInit(function()
    local tests = require("test_provisioning")

    local names = {}
    for name in pairs(tests) do table.insert(names, name) end
    table.sort(names)

    local passed, failed, failures = 0, 0, {}

    for _, name in ipairs(names) do
        _G.http.reset()
        _G.fskv.reset()

        log.info("test", "RUN ", name)
        local ok, err = pcall(tests[name])
        if ok then
            passed = passed + 1
            log.info("test", "PASS", name)
        else
            failed = failed + 1
            table.insert(failures, name .. ": " .. tostring(err))
            log.error("test", "FAIL", name)
            log.error("test", "  ", tostring(err))
        end
    end

    log.info("test", "------------------------------------")
    log.info("test", "SUMMARY", "passed", passed, "failed", failed)
    if failed > 0 then
        for _, f in ipairs(failures) do log.error("test", "FAILURE", f) end
        log.error("test", "UNITTEST_RESULT FAIL")
    else
        log.info("test", "UNITTEST_RESULT PASS")
    end

    sys.wait = real_sys_wait
    sys.wait(500)  -- let stdio drain to the log file

    if os and os.exit then
        os.exit(failed == 0 and 0 or 1)
    else
        rtos.reboot()
    end
end)

sys.run()
