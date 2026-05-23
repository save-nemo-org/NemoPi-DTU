-- Required by LuaTools for firmware generation.
-- Boots the same nemopi.lua application as the other platforms; only chip /
-- carrier-board specifics live here.
--
-- Target hardware: YED-GNSS2 carrier with an Air780EG module (EC618
-- silicon, integrated GNSS receiver). The chip's GNSS is reached via
-- pm.power(pm.GPS, …) + libgnss bound to the internal GNSS UART.
-- Sensor supply is NPN — drives nothing today, so noop in software.
-- Watchdog is doubled up: the modem's built-in wdt plus the external
-- AIR153C chip on GPIO28 (gnss2 branch's original design — keeps the
-- board alive even if the modem firmware itself stops feeding wdt).
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- Validate BSP. Air780EG ships as the same EC618 family as Air780XX, so
-- rtos.bsp() returns "EC618" here — same string as the D780L1-Y platform.
-- The two platforms are differentiated by which main.lua got flashed, not
-- by bsp(). Logged on every boot in case the string ever drifts.
local _bsp = rtos.bsp()
log.info("gnss2-platform", "rtos.bsp", _bsp)
assert(_bsp == "EC618", "EC618-family firmware only, got: " .. tostring(_bsp))

-- Hardware-specific knobs read by chip-agnostic code in src/.
-- GNSS2 specifics:
--   vbat divider 273300/3300 (~82.8x), matches the G2111Y-E carrier.
--   Sensor supply is NPN with nothing wired yet — noop until a relay
--     (NPN- or modbus-driven) is added.
--   GPS is the chip's integrated GNSS, talked to via the internal UART
--     bound by libgnss; pm.power(pm.GPS, …) gates the receiver.
_G.HW = {
    vbat_scale_num = 273300,
    vbat_scale_den = 3300,
    sensor_supply = { kind = "noop" },
    gps = { kind = "on_chip", uart_id = 2 },
}

-- Disable power key debouncing
if pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- Modem's built-in watchdog: 9 s timeout, fed every 3 s.
assert(wdt, "missing wdt module support")
wdt.init(9000)
sys.timerLoopStart(wdt.feed, 3000)

-- External AIR153C watchdog on GPIO28, fed every 150 s (matches the
-- chip's recommended interval per the manual).
local air153C_wtd = require("air153C_wtd")
sys.taskInit(function()
    air153C_wtd.init(28)
    while 1 do
        air153C_wtd.feed_dog(28)
        sys.wait(150 * 1000)
    end
end)

-- Forced reboot every 24 h. Long-lived state must survive a daily restart.
sys.timerStart(rtos.reboot, 24 * 3600 * 1000)

mobile.apn(0, 1, "hologram", "", "", nil, 0)

local nemopi = require("nemopi")

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
