local communication_service = {}

local system_service = require("system_service")
local modbus = require("modbus")
local utils = require("utils")
local sensors = require("sensors")

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
local mqtt_port = 8883
local imei = mobile.imei()
local pub_topic = "buoys/" .. imei .. "/d2c"
local sub_topic = "buoys/" .. imei .. "/c2d"

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

local function sms_setup()
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
end

sys.taskInit(function()

    assert(crypto.cipher_suites, "firmware missing crypto.cipher_suites support")
    assert(mqtt, "firmware missing mqtt support")
    assert(fskv, "firmware missing fskv support")

    local ret

    -- setup sms callback 
    sms_setup()

    -- mobile.setAuto(check_sim_period, get_cell_period, search_cell_time, auto_reset_stack, network_check_period)
    mobile.setAuto(10 * 1000, 5 * 60 * 1000, 5, true, 5 * 60 * 1000)

    -- setup internet access 
    log.info("ip", "wait")
    local ret = sys.waitUntil("IP_READY", 3 * 60 * 1000) -- 3 mins
    if not ret then
        log.error("ip", "timeout")
        utils.handle_error()
    end
    log.info("ip", "ready")

    -- sync system time
    socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"}, socket.LWIP_GP)
    local ret = sys.waitUntil("NTP_UPDATE", 180 * 1000) -- 3 mins
    if not ret then
        log.error("ntp", "failed")
        utils.handle_error()
    end
    log.info("ntp", "ready")

    utils.fskv_setup()

    -- fskv_set_cert_key(io.readFile("/luadb/client.crt"), io.readFile("/luadb/client.key")) -- tmp 

    local ret, cert, key = utils.fskv_get_cert_key()
    if not ret then
        log.error("mqtt", "failed to get mqtt cert and key")
        sys.wait(30 * 60 * 1000) -- idle for 30 mins to wait for key dispatch from server 
        -- TODO: request cert key from server 
        rtos.reboot()
    end

    -- setup mqtt
    local mqtt_ssl = {
        client_cert = cert,
        client_key = key,
        verify = 0
    }
    cert = nil
    key = nil

    local user_name = "client"
    local password = ""
    
    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_ssl)
    mqttc:auth(imei, user_name, password, true) -- client_id must have value, the last parameter true is for clean session
    mqttc:keepalive(60) -- default value 240s 
    mqttc:autoreconn(true, 3000) -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures 
    mqttc:debug(false)

    mqttc:on(function(mqtt_client, event, topic, payload)
        log.info("mqtt", "event", event, mqtt_client, topic, payload)
        if event == "conack" then
            mqttc:subscribe(sub_topic .. "/#")
            mqttc:publish(pub_topic .. "/conack", imei, 0)
            sys.publish("mqtt_conack")

        elseif event == "recv" then
            if ends_with(topic, "cmd") then
                local cb = function(msg)
                    mqttc:publish(pub_topic .. "/cmd", msg, 0)
                end
                system_service.system_call(cb, payload)
            end
        elseif event == "sent" then

        elseif event == "disconnect" then
            -- mqtt_client:connect()    -- required when autoreconn is false
        end
    end)

    -- connect mqtt
    log.info("mqtt", "connect", "wait")
    mqttc:connect()
    sys.waitUntil("mqtt_conack")
    log.info("mqtt", "connect", "ready")

    -- start sensoring task
    local UART_ID = 1
    local RS485_EN_GPIO = 25
    local VPCB_GPIO = 22 -- internal power to RS485 and ADC
    local VOUT_GPIO = 24 -- power output

    log.info("main", "setup")
    gpio.setup(VPCB_GPIO, 1, gpio.PULLUP)
    gpio.setup(VOUT_GPIO, 1, gpio.PULLUP)
    adc.setRange(adc.ADC_RANGE_3_8)

    modbus.enable(UART_ID, RS485_EN_GPIO)

    sys.wait(10 * 1000)
    
    local detected_sensors = {}
    do
        local telemetry = {
            type = "detect",
            sensors = {},
        }
    
        log.info("main", "detect")
        for name, sensor_class in pairs(sensors.sensor_classes) do
            log.info("main", "detect", name)
            local ret, detected = sensor_class:detect()
            if ret then
                log.info("main", "detected", name)
                table.insert(detected_sensors, detected)
                table.insert(telemetry.sensors, detected:info())
            end
        end

        mqttc:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
    end
    

    -- send detection telemetry

    

    -- modbus.modbus_setup()
    

    -- modbus.modbus_enable()
    -- sys.wait(10 * 1000)

    -- sys.wait(2000)
    -- modbus.modbus_disable()

    while 1 do

        -- modbus.modbus_enable()
        -- sys.wait(2000)
        do
            for index, sensor in ipairs(detected_sensors) do
                log.info("main", "run", "index", index)
                local info = sensor:info()
                local data = sensor:run()
                
                local telemetry = {
                    model = info.model,
                    interface = info.interface,
                    address = info.address,
                    data = data
                }
                mqttc:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
            end
        end
        

        -- do
        --     local ret, ds18b20 = modbus.modbus_read_ds18b20()
        --     if ret then
        --         mqttc:publish(pub_topic .. "telemetry/" .. "ds18b20", json.encode(ds18b20), 0)
        --     else
        --         mqttc:publish(pub_topic .. "telemetry/" .. "ds18b20", "NO_DATA", 0)
        --     end
        -- end

        -- do
        --     local ret, vbat = modbus.modbus_read_adc()
        --     if ret then
        --         mqttc:publish(pub_topic .. "telemetry/" .. "vbat", json.encode(vbat), 0)
        --     else
        --         mqttc:publish(pub_topic .. "telemetry/" .. "vbat", "NO_DATA", 0)
        --     end
        -- end
        
        -- sys.wait(1000)
        -- modbus.modbus_disable()

        sys.wait(30 * 1000)
    end
end)

return communication_service
