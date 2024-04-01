local system_service = {}

local libfota = require("libfota")

local system_call_table = {
    PING = function(cb)
        cb("OK")
        return true
    end,
    ECHO = function(cb, msg)
        cb(msg)
        return true
    end,
    REBOOT = function(cb)
        sys.timerStart(function()
            rtos.reboot()
        end, 60 * 1000)
        cb("DEVICE WILL REBOOT IN 60 SECONDS")
        return true
    end,
    MEM = function(cb)
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
        cb(json.encode(mem))
        return true
    end,
    MOBILE = function(cb)
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
        cb(json.encode(modem))
        return true
    end,
    CELL = function(cb)
        mobile.reqCellInfo(15)
        sys.taskInit(function()
            sys.waitUntil("CELL_INFO_UPDATE", 15 * 1000)
            cb(json.encode(mobile.getCellInfo()))
        end)
        return true
    end,
    OTA = function(cb, ota_url)
        function fota_cb(ret)
            if ret == 0 then
                cb("OTA COMPLETE, DEVICE WILL REBOOT IN 10 SECONDS")
                sys.timerStart(function()
                    rtos.reboot()
                end, 10 * 1000)
            else
                cb("OTA FAILED, ERROR CODE " .. tostring(ret))
            end
        end
        libfota.request(fota_cb, ota_url)
        cb("START OTA FROM URL " .. ota_url)
        return true
    end
}

function system_service.system_call(cb, str)
    -- parse str into cmd and args
    local iter = string.gmatch(str, "%S+")
    local cmd = iter()
    local args = {}
    for arg in iter do
        table.insert(args, arg)
    end
    -- validate command
    if cmd == nil then
        cb("Error: empty command")
        return false
    elseif cmd == "HELP" then
        local keys = {}
        for key, _ in pairs(system_call_table) do
            table.insert(keys, tostring(key))
        end
        cb("Supported commands: " .. table.concat(keys, ", "))
        return true
    end
    -- execute command
    local func = system_call_table[cmd]
    if func == nil then
        cb("Error: unsupported command: " .. cmd)
        return false
    end
    func(cb, table.unpack(args))
    return true
end

function system_service.register_system_call(cmd, func)
    assert(cmd ~= nil)
    assert(func ~= nil)
    system_call_table[cmd] = func
end

return system_service
