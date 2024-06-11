local sensors = {}
sensors.sensor_classes = {}

local UART_ID = 1
local modbus = require("modbus")

local function info(model, interface, address)
    return {
        model = model,
        interface = interface,
        address = address,
    }
end

local Gps = {}
sensors.sensor_classes.Gps = Gps

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

function Gps:detect()
    local obj = {}
    setmetatable(obj, self)
    self.__index = self

    for attempt = 1, 5 do
        log.debug("Gps", "detect", "attempt", attempt)
        local ret = read_gps()
        if ret == 0 or ret < -2 then
            log.debug("Gps", "detect", "detected")
            return true, obj
        end
    end

    log.error("Gps", "detect", "failed")
    return false
end

function Gps:info()
    return info("E108-D01", "rs485", 0x01)
end

function Gps:run()
    log.info("Gps", "run")
    for attempt = 1, 60 do
        log.debug("Gps", "run", "attempt", attempt)
        local ret, lat_lon = read_gps()
        if ret == 0 then
            assert(lat_lon)
            log.debug("Gps", "run", "lat", lat_lon["lat"], "lon", lat_lon["lon"])
            return lat_lon
        end
        sys.wait(2000)
    end
    log.error("Gps", "run", "timeout")
    return {
        fault = "failed to read GPS"
    }
end

return sensors
