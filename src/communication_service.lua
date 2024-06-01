local communication_service = {}

-- ######################################### INCLUDES #########################################

local system_service = require("system_service")
local modbus = require("modbus")

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

        modbus.modbus_read_gps(UART_ID)
        modbus.modbus_read_ds18b20(UART_ID)

        sys.wait(2000)
        -- modbus_read_input_register_16(UART_ID, 0x01, 0x00, 0x02)
        -- sys.wait(2000)
    end

end)

return communication_service
