local modbus = {}
modbus.debug = false

local function modbus_send(uart_id, slaveaddr, instruction, regaddr, value)
    local data = (string.format("%02x", slaveaddr) .. string.format("%02x", instruction) ..
        string.format("%04x", regaddr) .. string.format("%04x", value)):fromHex()
    local crc_data = pack.pack("<H", crypto.crc16("MODBUS", data))
    local data_tx = data .. crc_data
    if modbus.debug then
        log.debug("modbus", "send", "data", data_tx:toHex())
    end
    uart.write(uart_id, data_tx)
end

local function modbus_recv(uart_id, expected_slaveaddr, expected_instruction)
    local len = uart.rxSize(uart_id)
    local data = uart.read(uart_id, len)
    if modbus.debug then
        log.debug("modbus", "recv", "len", len, "data", data:toHex())
    end

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
    if modbus.debug then
        log.debug("modbus", "recv", "unpack", "slaveaddr", slaveaddr, "instruction", instruction, "size", size)
    end

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
function modbus.read_register(uart_id, slave, instruction, reg, len)
    assert(instruction == 0x03 or instruction == 0x04)
    -- clear rx buffer
    uart.rxClear(uart_id)
    -- send command
    modbus_send(uart_id, slave, instruction, reg, len)
    -- wait for process complete
    sys.wait(1000)
    -- read result
    local ret, _, _, size, data = modbus_recv(uart_id, slave, instruction)
    if not ret then
        log.error("modbus", "read_register", "failed to read modbus")
        return false
    end

    return true, size, data
end

function modbus.enable(uart_id, rs485_en_gpio)
    assert(uart_id)
    assert(rs485_en_gpio)
    log.info("modbus", "enable", "uart", uart_id)
    uart.setup(uart_id, 9600, 8, 1, uart.NONE, uart.LSB, 1024, rs485_en_gpio, 0, 5000) -- tx/rx switching delay: 20000 for 9600
    uart.on(uart_id, "sent", uart.wait485)
end

function modbus.disable(uart_id)
    uart.close(uart_id)
    log.info("modbus", "disable", "uart", uart_id)
end

return modbus
