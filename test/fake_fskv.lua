--[[
    fskv stub for unit tests. In-memory dict; reset/preload between tests.
    Implements just the surface the production modules use:
      init, status, iter/next, get, set, del.

    `snapshot()` returns a shallow copy of the current store for assertions.
]]
local M = {}

local store = {}

function M.reset()
    store = {}
end

function M.preload(t)
    for k, v in pairs(t) do store[k] = v end
end

function M.snapshot()
    local copy = {}
    for k, v in pairs(store) do copy[k] = v end
    return copy
end

-- Production-facing surface

function M.init() end

function M.status()
    local count = 0
    for _ in pairs(store) do count = count + 1 end
    return 0, 65536, count
end

function M.iter()
    local keys = {}
    for k in pairs(store) do table.insert(keys, k) end
    return {keys = keys, i = 0}
end

function M.next(it)
    it.i = it.i + 1
    return it.keys[it.i]
end

function M.get(key)
    return store[key]
end

function M.set(key, value)
    store[key] = value
    return true
end

function M.del(key)
    store[key] = nil
    return true
end

return M
