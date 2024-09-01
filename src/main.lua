-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

-- Disable power key debouncing
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- if rtos.bsp() == "EC618" and pm and pm.WORK_MODE then
--     log.setLevel(log.LOG_INFO)
--     pm.power(pm.WORK_MODE, 1)
--     pm.power(pm.USB, false)
--     pm.request(pm.LIGHT)
-- end

-- reboot every 24 hours
sys.timerStart(rtos.reboot, 24 * 3600 * 1000)

mobile.apn(0, 1, "hologram", "", "", nil, 0)
rtc.timezone(0)
socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

local nemopi = require("nemopi")

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
