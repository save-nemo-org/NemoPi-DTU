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

local function ip_setup()
    log.info("ip", "wait")
    local ret = sys.waitUntil("IP_READY", 3 * 60 * 1000) -- 3 mins
    if not ret then
        log.error("ip", "timeout")
        rtos.reboot()
    end
    log.info("ip", "ready")
end

local function sntp_setup()
    socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"}, socket.LWIP_GP)
    local ret = sys.waitUntil("NTP_UPDATE", 180 * 1000) -- 3 mins
    if not ret then
        log.error("ntp", "failed")
        -- shall we reboot? 
    end
    log.info("ntp", "updated")
end

local function fskv_setup()
    fskv.init()
    local used, total, kv_count = fskv.status()
    log.info("fskv", "used", used, "total", total, "kv_count", kv_count)

    -- print all data
    local iter = fskv.iter()
    if iter then
        while 1 do
            local k = fskv.next(iter)
            if not k then
                break
            end
            log.debug("fskv", "key", k, "value", fskv.get(k))
        end
    end
end

local function fskv_get_cert_key()
    local cert = fskv.get("cert")
    if not cert then
        log.error("fskv", "get", "cert", "not exist")
        return false
    end
    local key = fskv.get("key")
    if not cert then
        log.error("fskv", "get", "key", "not exist")
        return false
    end
    return true, cert, key
end

local function fskv_set_cert_key(cert, key)
    local ret
    if type(cert) ~= "string" then
        log.error("fskv", "set", "wrong cert type", type(cert))
        return false
    end
    if type(key) ~= "string" then
        log.error("fskv", "set", "wrong cert type", type(key))
        return false
    end
    ret = fskv.set("cert", cert)
    if not ret then
        log.error("fskv", "set", "failed to set cert")
        return false
    end
    ret = fskv.set("key", key)
    if not ret then
        log.error("fskv", "set", "failed to set key")
        return false
    end
    return true
end

sys.taskInit(function()

    assert(crypto.cipher_suites, "firmware missing crypto.cipher_suites support")
    assert(mqtt, "firmware missing mqtt support")
    assert(fskv, "firmware missing fskv support")

    local ret

    -- mobile.setAuto(check_sim_period, get_cell_period, search_cell_time, auto_reset_stack, network_check_period)
    mobile.setAuto(10 * 1000, 5 * 60 * 1000, 5, true, 5 * 60 * 1000)

    ip_setup()
    sntp_setup()
    fskv_setup()

    -- fskv_set_cert_key(io.readFile("/luadb/client.crt"), io.readFile("/luadb/client.key")) -- tmp 

    local ret, cert, key = fskv_get_cert_key()
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

    local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
    local mqtt_port = 8883

    local imei = mobile.imei()
    local client_id = imei
    local user_name = "client"
    local password = ""

    local pub_topic = "/" .. imei .. "/pub/"
    local sub_topic = "/" .. imei .. "/sub/"
    local sub_topic_table = {
        [sub_topic .. "cmd"] = 0,
    }

    -- Print topic base 
    log.info("task", "mqtt", "pub", pub_topic)
    log.info("task", "mqtt", "sub", json.encode(sub_topic_table))

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

    sys.taskInit(function()
    
        modbus.modbus_setup()
        sys.wait(1000)
    
        while 1 do

            modbus.modbus_enable()
            sys.wait(2000)
    
            modbus.modbus_blocking_read_gps(120)
            modbus.modbus_read_ds18b20()
            modbus.modbus_read_adc()
            
            sys.wait(1000)
            modbus.modbus_disable()
    
            sys.wait(30 * 1000)
        end
    end)
end)

return communication_service
