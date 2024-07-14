-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

-- log.setLevel(log.LOG_INFO)

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

local nemopi = require("nemopi")

-- Setup NET LED --
-- local netLed = require("netLed")
-- local NETLED_PIN = 27
-- netLed.setup(true, NETLED_PIN, nil)

-- sys.taskInit(function()
--     while 1 do
--         -- Print mem usage, debug only
--         sys.wait(60 * 1000)

--         log.info("lua", rtos.meminfo("lua"))
--         log.info("sys", rtos.meminfo("sys"))
--     end
-- end)

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
