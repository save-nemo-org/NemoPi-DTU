local power = {
    internal = {},
    gps = {},
}

local ADC_ID = 0

function power.setup()
    log.info("power", "setup")
    adc.setRange(adc.ADC_RANGE_MAX)

    uart.setup(2, 115200)
    libgnss.bind(2)
end

function power.internal.vbat()
    adc.open(ADC_ID)
    local result = 0
    for i = 1, 10 do
        local voltage = adc.get(ADC_ID) * 0.082818 -- mV / 1000 * 273300 / 3300
        result = result + voltage / 10
        sys.wait(100)
    end
    log.info("power", "internal", "vbat", result)
    adc.close(ADC_ID)
    return result
end

function power.gps.location()
    pm.power(pm.GPS, true)
    local lat_lon = nil
    for attempt = 1, 60 do
        if libgnss.isFix() then
            local lat, lon, speed = libgnss.getIntLocation()
            lat_lon = {
                lat = lat / 10000000,
                lon = lon / 10000000
            }
            log.debug("power", "gps", "location", "attempt", attempt, "lat", lat_lon.lat, "lon", lat_lon.lon)
            break
        else
            log.debug("power", "gps", "location", "attempt", attempt, "no fix")
            sys.wait(5000)
        end
    end
    pm.power(pm.GPS, false)

    return lat_lon
end

return power
