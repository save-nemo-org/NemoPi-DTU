local modbus = {}

local UART_ID = 1
local RS485_EN_GPIO = 25
local ADC_ID = 0
local VPCB_GPIO = 22 -- internal power to RS485 and ADC
local VOUT_GPIO = 24 -- power output

local function modbus_send(uart_id, slaveaddr, instruction, regaddr, value)
    local data =
        (string.format("%02x", slaveaddr) .. string.format("%02x", instruction) .. string.format("%04x", regaddr) ..
            string.format("%04x", value)):fromHex()
    local crc_data = pack.pack("<H", crypto.crc16("MODBUS", data))
    local data_tx = data .. crc_data
    log.debug("modbus", "send", "data", data_tx:toHex())
    uart.write(uart_id, data_tx)
end

local function modbus_recv(uart_id, expected_slaveaddr, expected_instruction)
    local len = uart.rxSize(uart_id)
    local data = uart.read(uart_id, len)
    log.debug("modbus", "recv", "len", len, "data", data:toHex())
    
    if len < 3 then
        log.error("modbus", "recv", "modbus frame too short", len)
        return false
    end

    local _, slaveaddr, instruction, size = pack.unpack(data, "<bbb")
    if expected_slaveaddr ~= slaveaddr then
        log.error("modbus", "recv", "incorrect slave addr", "expected", expected_slaveaddr, "received", slaveaddr)
        return false
    end
    if expected_instruction ~= instruction then
        log.error("modbus", "recv", "incorrect instruction", "expected", expected_instruction, "received", instruction)
        return false
    end
    if len < 3 + size + 2 then -- slave_addr, instruction, length, [length], crc, crc
        log.error("modbus", "recv", "modbus frame too short", len)
        return false
    end

    local _, crc = pack.unpack(data:sub(3 + size + 1, 3 + size + 1 + 2), "<H")
    local calculated_crc = crypto.crc16("MODBUS", data:sub(1, 3 + size))
    if calculated_crc ~= crc then
        log.error("modbus", "recv", "incorrect crc", "calculated", calculated_crc, "given", crc)
        return false
    end

    data = data:sub(4, 3 + size) -- data slice
    log.debug("modbus", "recv", "unpack", "slaveaddr", slaveaddr, "instruction", instruction, "size", size)
    
    return true, slaveaddr, instruction, size, data
end

-- read register by word
--
-- parameter: 
-- uart_id: uart port index
-- slave: slave id 0 - 255
-- instruction: 0x03 for holding register or 0x04 for input register 
-- reg: register address to read 
-- len: number of words to read 
-- 
-- return:
-- read result: true for success, false for failure 
-- size: received length in number of bytes
-- data: received data in string 
local function modbus_read_register(uart_id, slave, instruction, reg, len)
    if instruction ~= 0x03 and instruction ~= 0x04 then
        return false
    end
    -- clear rx buffer 
    uart.rxClear(uart_id) 
    -- send command 
    modbus_send(uart_id, slave, instruction, reg, len)
    -- wait for process complete
    sys.wait(1000)
    -- read result 
    local ret, _, _, size, data = modbus_recv(uart_id, slave, instruction)
    if not ret then
        log.error("modbus", "read_register_16", "failed to read modbus")
        return false
    end

    return true, size, data
end

local function modbus_read_gps()
    local ret, size, data = modbus_read_register(UART_ID, 0x01, 0x03, 0xC8, 0x0D) -- 13 words, 26 bytes
    if not ret then
        log.error("modbus", "read_gps", "failed to read gps")
        return -1
    end
    if size ~= 26 then
        log.error("modbus", "read_gps", "wrong data size", size)
        return -2
    end

    local gps_valid, _, _, _, _, _, _, lon_dir, lon, lat_dir, lat = select(2, pack.unpack(data, ">h7hfhf"))
    if gps_valid ~= 1 then
        log.error("modbus", "read_gps", "gps invalid")
        return -3
    end
    if lon_dir ~= 0x45 and lon_dir ~= 0x57 then
        log.error("modbus", "read_gps", "invalid gps longitude direction")
        return -4
    end
    if lat_dir ~= 0x4E and lat_dir ~= 0x53 then
        log.error("modbus", "read_gps", "invalid gps longitude direction")
        return -5
    end
    if lon_dir == 0x57 then
        lon = lon * -1
    end
    if lat_dir == 0x53 then
        lat = lat * -1
    end
    log.info("modbus", "read_gps", "lat", lat, "lon", lon)
    return 0, {lat = lat, lon = lon}
end

local Gps = {}

function Gps:detect()
    o = {}
    setmetatable(o, self)
    self.__index = self

    log.info("Gps", "detect")
    for attempt=1,5 do
        log.debug("Gps", "detect", "attempt", attempt)
        local ret = modbus_read_gps()
        if ret == 0 or ret < -2 then
            log.debug("Gps", "detect", "detected")
            return self
        end
    end
    log.error("Gps", "detect", "failed")
    return nil
end

function Gps:run()
    log.info("Gps", "run")
    for attempt=1,60 do
        log.debug("Gps", "run", "attempt", attempt)
        local ret, lat_lon = modbus_read_gps()
        if ret == 0 then
            log.debug("Gps", "run", "lat", lat_lon["lat"], "lon", lat_lon["lon"])
            return lat_lon
        end
        sys.wait(2000)
    end
    log.error("Gps", "run", "timeout")
    return nil
end

modbus.Gps = Gps

function modbus.modbus_read_ds18b20()
    -- read ds18b20 temperature 
    local ret, size, data = modbus_read_register(UART_ID, 0x02, 0x04, 0x10, 0x02)
    if not ret then
        log.error("modbus", "read_ds18b20", "failed to read ds18b20 data logger")
        return false
    end
    if size ~= 4 then
        log.error("modbus", "read_ds18b20", "wrong data size", size)
        return false
    end

    local result = {select(2, pack.unpack(data, ">h2"))}
    for key, value in pairs(result) do
        if value == -32768 then
            value = "NO SENSOR"
        else
            value = value / 10
        end
        log.info("modbus", "read_ds18b20", key, value)
        result[key] = value
    end
    return true, result
end

function modbus.modbus_read_adc()
    local voltage = adc.get(ADC_ID)*3300/103300
    log.info("modbus", "adc", ADC_ID, "voltage", voltage)
    return true, voltage
end

function modbus.modbus_setup()
    -- configure internal power control gpio
    gpio.setup(VPCB_GPIO, 0, gpio.PULLUP)
    log.info("modbus", "setup", "VPCB_GPIO", VPCB_GPIO)

    -- configure power output control gpio
    gpio.setup(VOUT_GPIO, 0, gpio.PULLUP)
    log.info("modbus", "setup", "VOUT_GPIO", VOUT_GPIO)

    -- configure external voltage sensoring adc
    adc.setRange(adc.ADC_RANGE_3_8)
    log.info("modbus", "setup", "adc", ADC_ID)
end

function modbus.modbus_enable()
    uart.setup(UART_ID, 9600, 8, 1, uart.NONE, uart.LSB, 1024, RS485_EN_GPIO, 0, 5000)  -- tx/rx switching delay: 20000 for 9600
    uart.on(UART_ID, "sent", uart.wait485)
    log.info("modbus", "enable", "uart", UART_ID)

    adc.open(ADC_ID)
    log.info("modbus", "enable", "adc", ADC_ID)

    -- turn on internal power
    gpio.set(VPCB_GPIO, 1)
    log.info("modbus", "enable", "internal power")

    -- turn on power output
    gpio.set(VOUT_GPIO, 1)
    log.info("modbus", "enable", "power output")
end

function modbus.modbus_disable()
    -- turn off power output
    gpio.set(VOUT_GPIO, 0)
    log.info("modbus", "disable", "internal power")

    -- turn off internal power 
    gpio.set(VPCB_GPIO, 0)
    log.info("modbus", "disable", "internal power")

    adc.close(ADC_ID)
    log.info("modbus", "disable", "adc", ADC_ID)

    uart.close(UART_ID)
    log.info("modbus", "disable", "uart", UART_ID)
end

return modbus