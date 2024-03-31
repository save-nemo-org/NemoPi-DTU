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
            ["sys_total"] = sys_total,
            ["sys_used"] = sys_used,
            ["sys_max_used"] = sys_max_used
        }
        return json.encode(mem)
    end,
    MEM_USAGE = function()
        local lua_total, lua_used, lua_max_used = rtos.meminfo("lua")
        local sys_total, sys_used, sys_max_used = rtos.meminfo("sys")
        local mem = {
            ["lua_used"] = lua_used / lua_total,
            ["lua_max_used"] = lua_max_used / lua_total,
            ["sys_used"] = sys_used / sys_total,
            ["sys_max_used"] = sys_max_used / sys_total
        }
        return json.encode(mem)
    end,
    IMEI = function()
        return mobile.imei()
    end,
    NUMBER = function()
        local number = mobile.number()
        if number == nil then
            return "Unknown"
        end
        return number
    end,
    BAND = function()
        local band = zbuff.create(40)
        mobile.getBand(band)
        local bands = {}
        for i = 0, band:used() - 1 do
            bands[#bands + 1] = string.format("%d", band[i])
        end
        return table.concat(bands, ",")
    end,
    CELL = function()
        mobile.reqCellInfo(15)
        sys.waitUntil("CELL_INFO_UPDATE", 15000) -- wait up to 15s
        return json.encode(mobile.getCellInfo())
    end,
    MQTT = function()
        if mqttc == nil then
            return "mqttc not initialised"
        else
            local mapping = {
                [mqtt.STATE_DISCONNECT] = "STATE_DISCONNECT",
                [mqtt.STATE_SCONNECT] = "STATE_SCONNECT",
                [mqtt.STATE_MQTT] = "STATE_MQTT",
                [mqtt.STATE_READY] = "STATE_READY"
            }
            return mapping[mqttc:state()]
        end
    end
}

function system_service.system_call_blocking(cmd)
    assert(cmd ~= nil)
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

function system_service.system_call(cmd, cb)
    assert(cmd ~= nil)
    assert(cb ~= nil)
    sys.publish("_SYS_CALL", cmd, cb)
end

-- taskInit will be executed when the require("tool") is called in main.lua
sys.taskInit(function()
    while true do
        local ret, cmd, cb = sys.waitUntil("_SYS_CALL", 300000)
        if ret then
            assert(cmd ~= nil)
            assert(cb ~= nil)
            local result = system_service.system_call_blocking(cmd)
            cb(result)
        end
    end
end)

return system_service
