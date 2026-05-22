--[[
    HTTP stub for unit tests. Queue-based: each test populates a FIFO of
    canned responses via `queue(...)`, then code under test consumes them
    via the standard `http.request(...).wait()` pattern.

    Recorded calls are inspectable via `calls()` for assertions like
    "exactly one /onboard request was made".

    Reset between tests with `reset()`.
]]
local M = {}

local responses = {}
local recorded_calls = {}

function M.reset()
    responses = {}
    recorded_calls = {}
end

-- response = {code = N, body = "...", headers = {...}}
function M.queue(response)
    table.insert(responses, response)
end

function M.calls()
    return recorded_calls
end

function M.request(method, url, headers, body)
    table.insert(recorded_calls, {
        method = method, url = url, headers = headers, body = body,
    })
    local response = table.remove(responses, 1) or {code = 500, body = ""}
    return {
        wait = function()
            return response.code, response.headers or {}, response.body or ""
        end,
    }
end

return M
