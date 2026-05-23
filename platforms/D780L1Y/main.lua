-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- Validate BSP
assert(rtos.bsp() == "EC618", "EC618 Firmware only")

-- Hardware-specific knobs read by chip-agnostic code in src/.
-- Carrier: YED-D780L1-Y on Air780XX (EC618). Direct sensor-supply GPIO
-- on GPIO24, vbat divider 3300/103300, GPS optional via modbus (slave
-- 0x01) when one is attached.
_G.HW = {
    vbat_scale_num = 3300,
    vbat_scale_den = 103300,
    sensor_supply = { kind = "direct", gpio = 24 },
    -- gps left as "none" by default; flip to "modbus" with the attached-GPS
    -- slave id when a unit actually has one wired up.
    gps = { kind = "none" },
}

-- Disable power key debouncing
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- wdt
assert(wdt, "missing wdt module support")
wdt.init(9000) -- wdt timeout 9s
sys.timerLoopStart(wdt.feed, 3000) -- feed every 3s

-- if rtos.bsp() == "EC618" and pm and pm.WORK_MODE then
--     log.setLevel(log.LOG_INFO)
--     pm.power(pm.WORK_MODE, 1)
--     pm.power(pm.USB, false)
--     pm.request(pm.LIGHT)
-- end

-- reboot every 24 hours
sys.timerStart(rtos.reboot, 24 * 3600 * 1000)

mobile.apn(0, 1, "hologram", "", "", nil, 0)

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
