local communication_service = {}

-- ######################################### INCLUDES #########################################

local system_service = require("system_service")

-- ######################################### HELPER FUNCTIONS #########################################

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

-- ######################################### SMS #########################################

sms.setNewSmsCb(function(num, txt, metas)
    local cb
    cb = function(msg)
        local segment_size = 140
        local segment = msg:sub(1, segment_size)
        sms.send(num, segment, false)
        if #msg > segment_size then
            sys.timerStart(cb, 1000, msg:sub(segment_size + 1))
        end
    end
    system_service.system_call(cb, txt)
end)

-- ######################################### MQTT #########################################

local mqttc = nil

system_service.register_system_call("MQTT", function(cb)
    if mqttc == nil then
        cb("NOT_INITIALISED")
    else
        local mqtt_state_name = {
            [mqtt.STATE_DISCONNECT] = "STATE_DISCONNECT",
            [mqtt.STATE_SCONNECT] = "STATE_SCONNECT",
            [mqtt.STATE_MQTT] = "STATE_MQTT",
            [mqtt.STATE_READY] = "STATE_READY"
        }
        cb(mqtt_state_name[mqttc:state()])
    end
    return true
end)

sys.taskInit(function()
    -- log.info("cipher", "suites", json.encode(crypto.cipher_suites()))
    assert(crypto.cipher_suites, "crypto.cipher_suites is not supported in the BSP")
    assert(mqtt, "MQTT is not supported in the BSP")

    local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
    local mqtt_port = 8883
    local mqtt_ssl = {
        client_cert = io.readFile("/luadb/client.crt"),
        client_key = io.readFile("/luadb/client.key"),
        verify = 0
    }

    local imei = mobile.imei()
    local client_id = imei
    local user_name = "client"
    local password = ""

    local pub_topic = "/" .. imei .. "/pub/"
    local sub_topic = "/" .. imei .. "/sub/"
    local sub_topic_table = {
        [sub_topic .. "cmd"] = 0,
    }

    -- Wait for IP Address
    sys.waitUntil("IP_READY")

    -- Print topic base 
    log.info("mqtt", "pub", pub_topic)
    log.info("mqtt", "sub", json.encode(sub_topic_table))

    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_ssl)
    mqttc:auth(client_id, user_name, password, true) -- client_id must have value, the last parameter true is for clean session
    mqttc:keepalive(60) -- default value 240s 
    mqttc:autoreconn(true, 3000) -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures 
    -- mqttc:debug(true)

    mqttc:on(function(mqtt_client, event, topic, payload)
        log.info("mqtt", "event", event, mqtt_client, topic, payload)
        if event == "conack" then
            sys.publish("mqtt_conack")
            sys.publish("SOCKET_ACTIVE", true) -- trigger LED
            mqttc:subscribe(sub_topic_table)
            mqttc:publish(pub_topic .. "telemetry", "Hello from " .. imei .. " on " .. os.date(), 0)
        elseif event == "recv" then
            if ends_with(topic, "cmd") then
                local cb = function(msg)
                    mqttc:publish(pub_topic .. "cmd", msg, 0)
                end
                system_service.system_call(cb, payload)
            end
        elseif event == "sent" then

        elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
            sys.publish("SOCKET_ACTIVE", false) -- trigger LED
        end
    end)

    mqttc:connect()
end)

local function modbus_send(uart_id, slaveaddr, instruction, regaddr, value)
    local data =
        (string.format("%02x", slaveaddr) .. string.format("%02x", instruction) .. string.format("%04x", regaddr) ..
            string.format("%04x", value)):fromHex()
    local crc_data = pack.pack("<H", crypto.crc16("MODBUS", data))
    local data_tx = data .. crc_data
    log.debug("modbus", "send", "data", data_tx:toHex())
    uart.write(uart_id, data_tx)
end

local function modbus_read(uart_id, expected_slaveaddr, expected_instruction)
    local len = uart.rxSize(uart_id)
    local data = uart.read(uart_id, len)
    log.debug("modbus", "recv", "len", len, "data", data:toHex())
    
    if len < 3 then
        log.error("modbus", "modbus frame too short", len)
        return false
    end

    local _, slaveaddr, instruction, size = pack.unpack(data, "<bbb")
    if expected_slaveaddr ~= slaveaddr then
        log.error("modbus", "incorrect slave addr", "expected", expected_slaveaddr, "received", slaveaddr)
        return false
    end
    if expected_instruction ~= instruction then
        log.error("modbus", "incorrect instruction", "expected", expected_instruction, "received", instruction)
        return false
    end
    if len < 3 + size + 2 then -- slave_addr, instruction, length, [length], crc, crc
        log.error("modbus", "modbus frame too short", len)
        return false
    end

    local _, crc = pack.unpack(data:sub(3 + size + 1, 3 + size + 1 + 2), "<H")
    local calculated_crc = crypto.crc16("MODBUS", data:sub(1, 3 + size))
    if calculated_crc ~= crc then
        log.error("modbus", "incorrect crc", "calculated", calculated_crc, "given", crc)
        return false
    end

    data = data:sub(4, 3 + size) -- data slice
    log.debug("modbus", "recv", "unpack", "slaveaddr", slaveaddr, "instruction", instruction, "size", size)
    
    return true, slaveaddr, instruction, size, data
end
  
local function modbus_read_input_register_16(uart_id, slave, reg, len)
    -- clear rx buffer 
    uart.rxClear(uart_id) 
    -- send command 
    modbus_send(uart_id, slave, 0x04, reg, len)
    -- wait for process complete
    sys.wait(1000)
    -- read result 
    local ret, slaveaddr, instruction, size, data = modbus_read(uart_id, slave, 0x04)
    if not ret then
        log.error("modbus", "read_input_register_16", "failed to read modbus")
        return false
    end
    -- unpack big endian
    if type(size) ~= "number" or size < 0 or size ~= math.floor(size) or size %2 ~= 0 then
        log.error("modbus", "read_input_register_16", "invalid data length", size)
        return false
    end
    local result = {select(2, pack.unpack(data, ">H" .. size/2))}

    return true, result
end

local function modbus_read_holding_register_16(uart_id, slave, reg, len)
    -- clear rx buffer 
    uart.rxClear(uart_id) 
    -- send command 
    modbus_send(uart_id, slave, 0x03, reg, len)
    -- wait for process complete
    sys.wait(1000)
    -- read result 
    local ret, slaveaddr, instruction, size, data = modbus_read(uart_id, slave, 0x03)
    if not ret then
        log.error("modbus", "read_holding_register_16", "failed to read modbus")
        return false
    end
    return true, size, data
end

local function modbus_read_gps(uart_id)
    local ret, size, data
    -- GPS validity
    ret, size, data = modbus_read_holding_register_16(uart_id, 0x01, 0xC8, 0x0D) -- 26 bytes
    if not ret then
        log.error("modbus", "read_gps", "failed to read gps validity register")
        return false
    end
    assert(size == 26)

    local gps_valid, _, _, _, _, _, _, lon_dir, lon, lat_dir, lat = select(2, pack.unpack(data, ">h7hfhf"))
    if gps_valid ~= 1 then
        log.error("modbus", "read_gps", "gps invalid")
        return false
    end
    if lon_dir ~= 0x45 and lon_dir ~= 0x57 then
        log.error("modbus", "read_gps", "invalid gps longitude direction")
        return false
    end
    if lat_dir ~= 0x4E and lat_dir ~= 0x53 then
        log.error("modbus", "read_gps", "invalid gps longitude direction")
        return false
    end
    if lon_dir == 0x57 then
        lon = lon * -1
    end
    if lat_dir == 0x53 then
        lat = lat * -1
    end
    log.info("modbus", "read_gps", "lat", lat, "lon", lon)
end

local function modbus_read_ds18b20(uart_id)
    -- read ds18b20 temperature 
    local ret, result = modbus_read_input_register_16(uart_id, 0x01, 0x00, 0x08)
    if ret then
        for key, value in pairs(result) do
            print(key, value)
        end
    end
end

sys.taskInit(function()
    local UART_ID = 1
    local VPCB_GPIO = 22 -- RS485 和ADC 运放电源
    local VOUT_GPIO = 24
    local RS485_EN_GPIO = 25

    -- config power output gpio
    gpio.setup(VPCB_GPIO, 0, gpio.PULLUP) -- enable PCB resource power 
    gpio.setup(VOUT_GPIO, 0, gpio.PULLUP) -- enable power output

    uart.setup(UART_ID, 9600, 8, 1, uart.NONE, uart.LSB, 1024, RS485_EN_GPIO, 0, 5000)  -- tx/rx switching delay: 20000 for 9600
    uart.on(UART_ID, "sent", uart.wait485)

    sys.wait(100)

    -- turn on internal power 
    gpio.set(VPCB_GPIO, 1)

    -- turn on power output
    gpio.set(VOUT_GPIO, 1)
    
    while 1 do

        sys.wait(2000)

        modbus_read_gps(UART_ID)

        sys.wait(2000)
        -- modbus_read_input_register_16(UART_ID, 0x01, 0x00, 0x02)
        -- sys.wait(2000)
    end

end)

return communication_service
