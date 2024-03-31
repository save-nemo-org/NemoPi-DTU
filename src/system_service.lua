local system_service = {}

local system_call_table = {
    PING = function()
        return "OK"
    end,
    REBOOT = function()
        sys.timerStart(function()
            rtos.reboot()
        end, 60 * 1000)
        return "DEVICE WILL REBOOT IN 60 SECONDS"
    end,
    MEM = function()
        local lua_total, lua_used, lua_max_used = rtos.meminfo("lua")
        local sys_total, sys_used, sys_max_used = rtos.meminfo("sys")
        local mem = {
            ["lua_total"] = lua_total,
            ["lua_used"] = lua_used,
            ["lua_max_used"] = lua_max_used,
            ["lua_used_presentage"] = lua_used / lua_total,
            ["lua_max_used_presentage"] = lua_max_used / lua_total,
            ["sys_total"] = sys_total,
            ["sys_used"] = sys_used,
            ["sys_max_used"] = sys_max_used,
            ["sys_used_presentage"] = sys_used / lua_total,
            ["sys_max_used_presentage"] = sys_max_used / lua_total
        }
        return json.encode(mem)
    end,
    IMEI = function()
        return mobile.imei()
    end,
    MOBILE = function()
        local band = zbuff.create(40)
        mobile.getBand(band)
        local bands = {}
        for i = 0, band:used() - 1 do
            bands[#bands + 1] = string.format("%d", band[i])
        end
        local modem = {
            ["IMEI"] = mobile.imei(),
            ["NUMBER"] = mobile.number(),
            ["BAND"] = table.concat(bands, ",")
        }
        return json.encode(modem)
    end,
    CELL = function()
        mobile.reqCellInfo(15)
        sys.waitUntil("CELL_INFO_UPDATE", 15000) -- wait up to 15s
        return json.encode(mobile.getCellInfo())
    end
}

function system_service.register_system_call(cmd, func)
    assert(cmd ~= nil)
    assert(func ~= nil)
    system_call_table[cmd] = func
end

function system_service.system_call(cmd)
    if cmd == "HELP" then
        local keys = {}
        for key, _ in pairs(system_call_table) do
            table.insert(keys, tostring(key))
        end
        return "Supported commands: " .. table.concat(keys, ", ")
    end
    local func = system_call_table[cmd]
    if func == nil then
        return "Unsupported command: " .. cmd
    end
    return func()
end

return system_service
