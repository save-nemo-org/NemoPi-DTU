local gps = {}

--[[
    GPS abstraction. The DTU's three carrier boards each have a different
    GPS arrangement, so this module dispatches on a platform-provided config:

        _G.HW.gps = { kind = "none" }
        _G.HW.gps = { kind = "on_chip", uart_id = 2 }
        _G.HW.gps = { kind = "on_board", uart_id = 2, power_gpio = 21 }
        _G.HW.gps = { kind = "modbus", uart_id = 1, slave = 0x01 }

    Notes:
      - "on_chip" assumes the modem chip integrates a GNSS receiver
        (Air780EG family) and is power-cycled via `pm.power(pm.GPS, …)`.
      - "on_board" assumes a separate GPS chip on the carrier with its
        own power rail on `power_gpio` and a UART for NMEA data.
      - "modbus" is the legacy attached-GPS-over-RS485 setup. The GPS
        device draws power from the sensor supply bus, so the caller
        must have `power.external` (the sensor supply) enabled before
        calling `gps.location()`. The other kinds manage their own power.

    Each kind exposes the same surface: `gps.setup()` once at boot, then
    `gps.location()` per read. `location()` returns a table with
        { lat, lon, alt, satellites, hdop }
    or nil on timeout / no fix / "none".
]]

-- ============================================================
-- libgnss-backed kinds (on_chip, on_board)
-- ============================================================

-- Wait up to ~5 minutes for a fix, then return a parsed location or nil.
-- Mirrors the 60×5s pattern from the gnss2 branch — long enough for a
-- cold start with reasonable sky view, short enough that a missing
-- antenna doesn't wedge the read cycle for the rest of the day.
local function wait_for_fix_and_read()
    local libgnss = require("libgnss")
    for attempt = 1, 60 do
        if libgnss.isFix() and libgnss.getGga(2) then
            sys.wait(10000)  -- let the fix settle before sampling
            local gga = libgnss.getGga(2)
            if gga and gga.latitude and gga.longitude then
                local result = {
                    lat = gga.latitude,
                    lon = gga.longitude,
                    alt = gga.altitude,
                    satellites = gga.satellites_tracked,
                    hdop = gga.hdop,
                }
                log.info("gps", "fix", "attempt", attempt, json.encode(result))
                return result
            end
        end
        log.debug("gps", "wait_fix", "attempt", attempt)
        sys.wait(5000)
    end
    log.error("gps", "wait_fix", "timeout after 60 attempts (~5 min)")
    return nil
end

-- ============================================================
-- "modbus" backend (legacy modbus-attached GPS)
-- ============================================================

local function read_modbus_gps(uart_id, slave)
    local modbus = require("modbus")
    local ret, size, data = modbus.read_register(uart_id, slave, 0x03, 0xC8, 0x0D)  -- 13 words = 26 bytes
    if not ret then return nil, "modbus read failed" end
    if size ~= 26 then return nil, "wrong data size " .. tostring(size) end

    local lock, _, _, _, _, _, _, lon_dir, lon, lat_dir, lat = select(2, pack.unpack(data, ">h7hfhf"))
    if lock ~= 1 then return nil, "gps not locked" end
    if lon_dir ~= 0x45 and lon_dir ~= 0x57 then return nil, "invalid lon direction" end
    if lat_dir ~= 0x4E and lat_dir ~= 0x53 then return nil, "invalid lat direction" end
    if lon_dir == 0x57 then lon = lon * -1 end
    if lat_dir == 0x53 then lat = lat * -1 end
    return {lat = lat, lon = lon}
end

-- ============================================================
-- Public API
-- ============================================================

-- One-time init per boot. Safe to call before HW.gps is set (returns nil
-- silently if no GPS is configured).
function gps.setup()
    local cfg = HW and HW.gps
    if not cfg or cfg.kind == "none" then
        log.info("gps", "setup", "kind", "none")
        return
    end

    if cfg.kind == "on_chip" then
        assert(cfg.uart_id, "HW.gps.uart_id required for on_chip")
        local libgnss = require("libgnss")
        uart.setup(cfg.uart_id, 115200)
        libgnss.bind(cfg.uart_id)
        log.info("gps", "setup", "kind", "on_chip", "uart", cfg.uart_id)
        return
    end

    if cfg.kind == "on_board" then
        assert(cfg.uart_id, "HW.gps.uart_id required for on_board")
        assert(cfg.power_gpio, "HW.gps.power_gpio required for on_board")
        local libgnss = require("libgnss")
        gpio.setup(cfg.power_gpio, 0)  -- output, default off
        uart.setup(cfg.uart_id, 115200)
        libgnss.bind(cfg.uart_id)
        log.info("gps", "setup", "kind", "on_board", "uart", cfg.uart_id, "power_gpio", cfg.power_gpio)
        return
    end

    if cfg.kind == "modbus" then
        log.info("gps", "setup", "kind", "modbus", "uart", cfg.uart_id, "slave", cfg.slave)
        return  -- modbus bus is set up by the modbus module / sensors path
    end

    log.error("gps", "setup", "unknown kind", tostring(cfg.kind))
end

-- Read a single location fix. Returns {lat, lon, alt?, satellites?, hdop?}
-- or nil on failure. Caller-supplied power for "modbus" (sensor supply
-- must be on); self-managed power for the libgnss-backed kinds.
function gps.location()
    local cfg = HW and HW.gps
    if not cfg or cfg.kind == "none" then return nil end

    if cfg.kind == "on_chip" then
        pm.power(pm.GPS, true)
        local result = wait_for_fix_and_read()
        pm.power(pm.GPS, false)
        return result
    end

    if cfg.kind == "on_board" then
        gpio.set(cfg.power_gpio, 1)
        local result = wait_for_fix_and_read()
        gpio.set(cfg.power_gpio, 0)
        return result
    end

    if cfg.kind == "modbus" then
        for attempt = 1, 60 do
            local result, err = read_modbus_gps(cfg.uart_id or 1, cfg.slave or 0x01)
            if result then
                log.info("gps", "modbus fix", "attempt", attempt, "lat", result.lat, "lon", result.lon)
                return result
            end
            log.debug("gps", "modbus", "attempt", attempt, "err", err)
            sys.wait(2000)
        end
        log.error("gps", "modbus", "timeout after 60 attempts")
        return nil
    end

    log.error("gps", "location", "unknown kind", tostring(cfg.kind))
    return nil
end

return gps
