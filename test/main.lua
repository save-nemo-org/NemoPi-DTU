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

-- Polling code uses sys.wait; we want tests to finish instantly, so stub
-- it to a complete no-op. The test runner is single-tasked (everything
-- runs inside one sys.taskInit below) so there's nothing else that needs
-- the cooperative scheduler to tick between waits. Note: we can't call
-- sys.wait(0) as a "yield-only" wait — LuatOS docs say the timeout must
-- be > 0 or the call is undefined.
local real_sys_wait = sys.wait  -- restored before exit so log drain works
sys.wait = function() end

-- Register each test suite as {name, tests}. Requires must be literal
-- strings so LuatOS's dependency-trimming pass keeps the suite files in
-- the bundle (`require(variable)` is dynamic and gets dropped). To add
-- a new suite, drop a file under test/ exposing { test_xxx = fn, … }
-- and append a new {name = "...", tests = require("...")} entry.
local suites = {
    {name = "test_provisioning",  tests = require("test_provisioning")},
    {name = "test_fskv_migrate",  tests = require("test_fskv_migrate")},
}

sys.taskInit(function()
    local passed, failed, failures = 0, 0, {}

    for _, suite in ipairs(suites) do
        local suite_name = suite.name
        local tests = suite.tests
        local names = {}
        for name in pairs(tests) do table.insert(names, name) end
        table.sort(names)

        for _, name in ipairs(names) do
            _G.http.reset()
            _G.fskv.reset()

            local qualified = suite_name .. "::" .. name
            log.info("test", "RUN ", qualified)
            local ok, err = pcall(tests[name])
            if ok then
                passed = passed + 1
                log.info("test", "PASS", qualified)
            else
                failed = failed + 1
                table.insert(failures, qualified .. ": " .. tostring(err))
                log.error("test", "FAIL", qualified)
                log.error("test", "  ", tostring(err))
            end
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
