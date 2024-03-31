local mqtt_service = {}

local mqtt_state_name = {
    [mqtt.STATE_DISCONNECT] = "STATE_DISCONNECT",
    [mqtt.STATE_SCONNECT] = "STATE_SCONNECT",
    [mqtt.STATE_MQTT] = "STATE_MQTT",
    [mqtt.STATE_READY] = "STATE_READY"
}

local mqttc = nil

local system_service = require("system_service")
system_service.register_system_call("MQTT", function()
    if mqttc == nil then
        return "NOT_INITIALISED"
    end
    return mqtt_state_name[mqttc:state()]
end)

-- Some utility function
local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

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

    local imei = system_service.system_call("IMEI")
    local client_id = imei
    local user_name = "client"
    local password = ""

    local pub_topic = "/" .. imei .. "/pub/"
    local sub_topic = "/" .. imei .. "/sub/"
    local sub_topic_table = {
        [sub_topic .. "echo"] = 0,
        [sub_topic .. "cmd"] = 0
    }

    -- Wait for IP Address
    sys.waitUntil("IP_READY")

    -- Print topic base 
    log.info("mqtt", "pub", pub_topic)
    log.info("mqtt", "sub", json.encode(sub_topic_table))

    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_ssl)
    mqttc:auth(client_id, user_name, password) -- client_id must have value 
    mqttc:keepalive(60) -- default value 240s 
    mqttc:autoreconn(true, 3000) -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures 
    -- mqttc:debug(true)

    mqttc:on(function(mqtt_client, event, topic, payload)
        log.info("mqtt", "event", event, mqtt_client, topic, payload)
        if event == "conack" then
            sys.publish("mqtt_conack")
            sys.publish("SOCKET_ACTIVE", true) -- trigger LED
        elseif event == "recv" then
            sys.publish("mqtt_recv", topic, payload)
        elseif event == "sent" then

        elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
            sys.publish("SOCKET_ACTIVE", false) -- trigger LED
        end
    end)

    -- mqttc自动处理重连, 除非自行关闭
    mqttc:connect()
    sys.waitUntil("mqtt_conack")
    mqttc:subscribe(sub_topic_table)

    if mqttc and mqttc:ready() then
        local pkgid = mqttc:publish(pub_topic .. "telemetry", "message from " .. imei .. " on " .. os.date(), 0)
    end

    while true do
        local ret, topic, data, qos = sys.waitUntil("mqtt_recv", 60 * 1000)
        if ret then
            if ends_with(topic, "cmd") then
                local result = system_service.system_call(data)
                mqttc:publish(pub_topic .. "cmd", result, 0)
            end
        end
    end

    mqttc:close()
    mqttc = nil
end)

return mqtt_service
