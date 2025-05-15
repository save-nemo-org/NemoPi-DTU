-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- PC simulation firmware only
assert(rtos.bsp() == "PC", "PC Firmware only")

-- Loading missing modules 
_G.mobile = require("mobile")
_G.sms = require("sms")

local nemopi = require("nemopi")

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
