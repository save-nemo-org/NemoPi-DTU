-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- PC simulation firmware only
assert(rtos.bsp() == "PC", "PC Firmware only")

-- Hardware-specific knobs read by chip-agnostic code in src/. The simulator
-- has stubbed gpio/adc with no real wiring behind them; declare both rails
-- as no-ops so power.lua/gps.lua don't toggle phantom pins.
_G.HW = {
    vbat_scale_num = 3300,
    vbat_scale_den = 103300,
    sensor_supply = { kind = "noop" },
    gps = { kind = "none" },
}

-- Loading missing modules
_G.mobile = require("mobile")
_G.sms = require("sms")

local nemopi = require("nemopi")

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
