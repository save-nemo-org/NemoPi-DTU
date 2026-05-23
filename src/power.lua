local power = {
    internal = {},
    external = {},
}

--[[
    Power rails. Two domains:

      - `internal`: VPCB on a fixed GPIO22 — feeds the modem's RS485
        transceiver and the vbat ADC divider. Same wiring on every board
        we ship, so the GPIO + ADC channel are hard-coded here.

      - `external`: the sensor supply bus. Wiring varies per board:
          D780L1-Y has a direct GPIO that powers sensors on/off.
          G2111Y-E / GNSS2 have an NPN output that today drives nothing
          useful, so the on/off calls are no-ops until a relay (NPN- or
          modbus-driven) is wired in. The platform's main.lua picks the
          backend by setting `_G.HW.sensor_supply`:
              { kind = "direct", gpio = 24 }
              { kind = "noop" }
          Future kinds (npn_relay, modbus_relay) slot in here without
          changes to nemopi.lua or any callers.
]]

local ADC_ID = 0
local VPCB_GPIO = 22 -- internal power to RS485 and ADC

function power.setup()
    log.info("power", "setup")
    gpio.setup(VPCB_GPIO, 0, gpio.PULLUP)
    adc.setRange(adc.ADC_RANGE_3_8)

    local cfg = HW and HW.sensor_supply
    if cfg and cfg.kind == "direct" then
        assert(cfg.gpio, "HW.sensor_supply.gpio required for kind=direct")
        gpio.setup(cfg.gpio, 0, gpio.PULLUP)
        log.info("power", "setup", "external", "direct", "gpio", cfg.gpio)
    elseif cfg and cfg.kind == "noop" then
        log.info("power", "setup", "external", "noop")
    else
        -- Default: legacy direct GPIO24 (D780L1-Y carrier).
        gpio.setup(24, 0, gpio.PULLUP)
        log.info("power", "setup", "external", "direct (default)", "gpio", 24)
    end
end

function power.internal.enable()
    log.info("power", "internal", "enable")
    gpio.set(VPCB_GPIO, 1)
    adc.open(ADC_ID)
end

function power.internal.disable()
    log.info("power", "internal", "disable")
    gpio.set(VPCB_GPIO, 0)
    adc.close(ADC_ID)
end

function power.internal.vbat()
    -- vbat scaling depends on the carrier board's resistor divider.
    -- Platform main.lua sets _G.HW.vbat_scale_num / vbat_scale_den per board;
    -- defaults preserve the original D780L1-Y carrier behaviour.
    --   vbat = adc.get(ADC_ID) * vbat_scale_num / vbat_scale_den
    local num = (HW and HW.vbat_scale_num) or 3300
    local den = (HW and HW.vbat_scale_den) or 103300
    local result = 0
    for i = 1, 10 do
        local voltage = adc.get(ADC_ID) * num / den
        result = result + voltage / 10
        sys.wait(100)
    end
    log.info("power", "internal", "vbat", result)
    return result
end

local function sensor_supply()
    return (HW and HW.sensor_supply) or {kind = "direct", gpio = 24}
end

function power.external.enable()
    local cfg = sensor_supply()
    if cfg.kind == "direct" then
        log.info("power", "external", "enable", "direct", "gpio", cfg.gpio)
        gpio.set(cfg.gpio, 1)
    elseif cfg.kind == "noop" then
        log.info("power", "external", "enable", "noop")
        -- nothing to do — sensors are externally powered or always-on
    else
        log.error("power", "external", "enable", "unknown kind", tostring(cfg.kind))
    end
end

function power.external.disable()
    local cfg = sensor_supply()
    if cfg.kind == "direct" then
        log.info("power", "external", "disable", "direct", "gpio", cfg.gpio)
        gpio.set(cfg.gpio, 0)
    elseif cfg.kind == "noop" then
        log.info("power", "external", "disable", "noop")
    else
        log.error("power", "external", "disable", "unknown kind", tostring(cfg.kind))
    end
end

return power
