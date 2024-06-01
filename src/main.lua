-- Required by LuaTools for firmware generation 
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

--[[
MQTT is an inbuilt lib, so user doesn't need to import it explicitly 
]]

-- Sys is a required lib 
_G.sys = require("sys")
-- MQTT application need this lib 
_G.sysplus = require("sysplus")

-- log.setLevel(log.LOG_INFO)

-- Air780E的AT固件默认会为开机键防抖, 导致部分用户刷机很麻烦
-- Disable power key debouncing 
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- if rtos.bsp() == "EC618" and pm and pm.WORK_MODE then
--     pm.power(pm.WORK_MODE, 1)
-- end

-- 自动低功耗, 轻休眠模式
-- Air780E支持uart唤醒和网络数据下发唤醒, 但需要断开USB,或者pm.power(pm.USB, false) 但这样也看不到日志了
-- Enable auto sleep
-- pm.request(pm.LIGHT)

rtc.timezone(0)
socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")
socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"}, socket.LWIP_GP)

local communication_service = require("communication_service")

-- Setup NET LED --
local netLed = require("netLed")
local NETLED_PIN = 27
netLed.setup(true, NETLED_PIN, nil)

-- sys.taskInit(function()
--     while 1 do
--         -- Print mem usage, debug only
--         sys.wait(10 * 1000)

--         local total_lua, used_lua, max_used_lua = rtos.meminfo("lua")
--         log.info("lua", used_lua / total_lua, max_used_lua / total_lua)

--         local total_sys, used_sys, max_used_sys = rtos.meminfo("sys")
--         log.info("sys", used_sys / total_sys, max_used_sys / total_sys)
--     end
-- end)

-- End of User Code ---------------------------------------------
-- Start scheduler 
sys.run()
-- Don't program after sys.run()
