local power = {
    internal = {},
    external = {},
}

local ADC_ID = 0
local VPCB_GPIO = 22 -- internal power to RS485 and ADC
local VOUT_GPIO = 24 -- power output

function power.setup()
    log.info("power", "setup")
    gpio.setup(VPCB_GPIO, 0, gpio.PULLUP)
    gpio.setup(VOUT_GPIO, 0, gpio.PULLUP)
    adc.setRange(adc.ADC_RANGE_3_8)
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
    -- defaults preserve the original EC618 carrier behaviour.
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

function power.external.enable()
    log.info("power", "external", "enable")
    gpio.set(VOUT_GPIO, 1)
end

function power.external.disable()
    log.info("power", "external", "disable")
    gpio.set(VOUT_GPIO, 0)
end

return power
