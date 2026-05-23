-- Required by LuaTools for firmware generation.
-- Boots the same nemopi.lua application as the EC618 platform; only chip /
-- carrier-board specifics live here.
--
-- Target hardware: YED G2111Y-E (Yinerda) carrier board with a Y100EP module
-- (Hezhou Air780EP rebadge, EC718 silicon, RS485 variant). Pinout cross-ref:
-- 银尔达Air780系列产品二次开发手册.pdf §45.
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

log.setLevel(log.LOG_INFO)

-- Validate BSP. Confirmed value on V2024 Air780EP firmware: "EC718P".
-- Tolerance kept for plausible alternate labels (different LuatOS BSP
-- versions have been known to shift these strings); the log line below
-- gives ground truth on each boot so any future drift is obvious.
local _bsp = rtos.bsp()
log.info("ec718-platform", "rtos.bsp", _bsp)
assert(_bsp == "EC718P" or _bsp == "EC718" or _bsp == "Air780EP",
    "EC718-family firmware only, got: " .. tostring(_bsp))

-- Hardware-specific knobs read by chip-agnostic code in src/.
-- G2111Y-E specifics:
--   vbat divider 273300/3300 (~82.8x, designed for inputs up to 90 V)
--   sensor supply is NPN on GPIO24 — drives nothing useful yet, so noop
--     until a relay (NPN- or modbus-driven) is wired in
--   GPS is the on-board chip on UART2, powered via GPIO21 (per
--     银尔达Air780系列产品二次开发手册.pdf §45)
_G.HW = {
    vbat_scale_num = 273300,
    vbat_scale_den = 3300,
    sensor_supply = { kind = "noop" },
    -- Confirmed on real hardware (commit message): 9600 baud yields a
    -- valid fix on the YED-bundled on-board GPS module; that's also the
    -- module's factory default, so the default in gps.lua is enough.
    gps = { kind = "on_board", uart_id = 2, power_gpio = 21 },
}

-- Air780EP carrier doesn't expose the chip's PWK debouncing knob the same
-- way EC618 does; guarded so we no-op if pm.PWK_MODE isn't present.
if pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- External windowed watchdog (AIR153C-style) lives on GPIO28 on this
-- carrier. Toggle every 100 s — comfortably under the manual's recommended
-- 150 s ceiling, slow enough that a windowed implementation won't reset us
-- for kicking too fast. The chip's `wdt` module on the modem itself is not
-- the same thing and is not used here.
local EXT_WDT_GPIO = 28
local ext_wdt_state = 0
gpio.setup(EXT_WDT_GPIO, ext_wdt_state)
sys.timerLoopStart(function()
    ext_wdt_state = 1 - ext_wdt_state
    gpio.set(EXT_WDT_GPIO, ext_wdt_state)
end, 100 * 1000)

-- Forced reboot every 24 h. Long-lived state must survive a daily restart.
sys.timerStart(rtos.reboot, 24 * 3600 * 1000)

mobile.apn(0, 1, "hologram", "", "", nil, 0)

local nemopi = require("nemopi")

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
