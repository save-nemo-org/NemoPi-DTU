-- Minimal assertion helpers. Each raises with level=2 so the failure line in
-- the test file (the caller) is reported, not the assertion's own line.
local M = {}

function M.assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\n  expected: %s\n  actual:   %s",
            msg or "assert_eq failed", tostring(expected), tostring(actual)), 2)
    end
end

function M.assert_truthy(v, msg)
    if not v then
        error(msg or "assert_truthy failed (got nil/false)", 2)
    end
end

function M.assert_nil(v, msg)
    if v ~= nil then
        error(string.format("%s\n  expected: nil\n  actual:   %s",
            msg or "assert_nil failed", tostring(v)), 2)
    end
end

-- Substring (literal, not pattern) containment check.
function M.assert_contains(str, needle, msg)
    if type(str) ~= "string" or not string.find(str, needle, 1, true) then
        error(string.format("%s\n  expected to contain: %s\n  actual:              %s",
            msg or "assert_contains failed", tostring(needle), tostring(str)), 2)
    end
end

return M
