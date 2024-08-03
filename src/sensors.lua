local sensors = {}
sensors.sensor_classes = {}
sensors.infrastructure = {}

local UART_ID = 1
local modbus = require("modbus")

local function info(model, interface, address, feature)
    return {
        model = model,
        interface = interface,
        address = address,
        feature = feature,
    }
end

-- ##############################################################################################################################

local Gps = {}
sensors.infrastructure.Gps = Gps

local function read_gps()
    local ret, size, data = modbus.read_register(UART_ID, 0x01, 0x03, 0xC8, 0x0D) -- 13 words, 26 bytes
    if not ret then
        log.error("Gps", "read_gps", "failed to read gps")
        return -1
    end
    if size ~= 26 then
        log.error("Gps", "read_gps", "wrong data size", size)
        return -2
    end

    local lock, _, _, _, _, _, _, lon_dir, lon, lat_dir, lat = select(2, pack.unpack(data, ">h7hfhf"))
    if lock ~= 1 then
        log.error("Gps", "read_gps", "gps not locked")
        return -3
    end
    if lon_dir ~= 0x45 and lon_dir ~= 0x57 then
        log.error("Gps", "read_gps", "invalid gps longitude direction")
        return -4
    end
    if lat_dir ~= 0x4E and lat_dir ~= 0x53 then
        log.error("Gps", "read_gps", "invalid gps longitude direction")
        return -5
    end
    if lon_dir == 0x57 then
        lon = lon * -1
    end
    if lat_dir == 0x53 then
        lat = lat * -1
    end
    log.info("Gps", "read_gps", "lat", lat, "lon", lon)
    return 0, {
        lat = lat,
        lon = lon
    }
end

function Gps:read()
    log.info("Gps", "run")
    for attempt = 1, 60 do
        log.debug("Gps", "run", "attempt", attempt)
        local ret, lat_lon = read_gps()
        if ret == 0 then
            assert(lat_lon)
            return lat_lon
        end
        sys.wait(2000)
    end
    log.error("Gps", "run", "timeout")
end

-- ##############################################################################################################################

local function read_ds18b20_logger()
    -- read ds18b20 temperature
    local ret, size, data = modbus.read_register(UART_ID, 0x02, 0x04, 0x10, 0x02)
    local sensor_results = {}
    if not ret then
        log.error("Ds18b20Logger", "read_ds18b20", "failed to read ds18b20 data logger")
        table.insert(sensor_results, {
            channel = "ch1",
            value = json.null,
            fault = "ds18b20 logger unreachable"
        })
        table.insert(sensor_results, {
            channel = "ch2",
            value = json.null,
            fault = "ds18b20 logger unreachable"
        })
        return false, sensor_results
    end
    if size ~= 4 then
        log.error("Ds18b20Logger", "read_ds18b20", "wrong data size", size)
        table.insert(sensor_results, {
            channel = "ch1",
            value = json.null,
            fault = "ds18b20 logger return data invalid"
        })
        table.insert(sensor_results, {
            channel = "ch2",
            value = json.null,
            fault = "ds18b20 logger return data invalid"
        })
        return false, sensor_results
    end

    local result = { select(2, pack.unpack(data, ">h2")) }

    if result[1] ~= -32768 then
        table.insert(sensor_results, {
            channel = "ch1",
            value = result[1] / 10.0,
            fault = ""
        })
    else
        table.insert(sensor_results, {
            channel = "ch1",
            value = json.null,
            fault = "sensor unreachable"
        })
    end
    
    if result[2] ~= -32768 then
        table.insert(sensor_results, {
            channel = "ch2",
            value = result[2] / 10.0,
            fault = ""
        })
    else
        table.insert(sensor_results, {
            channel = "ch2",
            value = json.null,
            fault = "sensor unreachable"
        })
    end

    return true, sensor_results
end

local Ds18b20Logger = {
    feature = {
        ch1 = false,
        ch2 = false,
    },
}
sensors.sensor_classes.Ds18b20Logger = Ds18b20Logger

function Ds18b20Logger:detect()
    local obj = {}
    setmetatable(obj, self)
    self.__index = self

    local ret, result = read_ds18b20_logger()
    if not ret then
        log.error("Ds18b20Logger", "detect", "failed")
        return false
    end

    log.debug("Ds18b20Logger", "detect", "detected")
    obj.feature.ch1 = result[1]["value"] ~= json.null
    obj.feature.ch2 = result[2]["value"] ~= json.null
    return true, obj
end

function Ds18b20Logger:info()
    return info("DS18B20-LOGGER", "rs485", 0x02, self.feature)
end

function Ds18b20Logger:run()
    log.info("Ds18b20Logger", "run")

    local ret, result = read_ds18b20_logger()
    assert(ret ~= nil)
    assert(result ~= nil)
    return result
end

return sensors
