local mqtt_service = {}

local system_service = require("system_service")
-- mqtt client object 
local mqttc = nil

-- Server config 
local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
local mqtt_port = 8883
local mqtt_ssl = {
    client_cert = io.readFile("/luadb/client.crt"),
    client_key = io.readFile("/luadb/client.key"),
    verify = 0
}

-- Some utility function
local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

sys.taskInit(function()
    -- Print cipher_suites
    assert(crypto.cipher_suites, "crypto.cipher_suites is not supported in the BSP")
    assert(mqtt,  "MQTT is not supported in the BSP")

    local imei = system_service.system_call_blocking("IMEI")
    local client_id = imei
    local user_name = "client"
    local password = ""

    local pub_topic = "/" .. imei .. "/pub/"
    local sub_topic = "/" .. imei .. "/sub/"
    local sub_topic_table = {
        [sub_topic .. "echo"] = 0,
        [sub_topic .. "cmd"] = 0,
    }

    -- Wait for IP Address
    sys.waitUntil("IP_READY")

    -- Print IP
    log.info("socket", "ip", socket.localIP(socket.LWIP_GP))
    
    -- Set DNS
    socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

    -- Update time 
    socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"})

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
            sys.publish("SOCKET_ACTIVE", true)  -- trigger LED
            mqtt_client:subscribe(sub_topic_table)
        elseif event == "recv" then
            log.info("mqtt", "downlink", "topic", topic, "payload", payload)
            if ends_with(topic, "cmd") then
                local mqtt_cb = function(msg)
                    mqttc:publish(pub_topic .. "cmd", msg, 0)
                end
                system_service.system_call(payload, mqtt_cb)
            end
            -- sys.publish("mqtt_payload", topic, payload)
        elseif event == "sent" then
            -- log.info("mqtt", "sent", "pkgid", data)
        elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
            sys.publish("SOCKET_ACTIVE", false)  -- trigger LED
        end
    end)

    -- mqttc自动处理重连, 除非自行关闭
    mqttc:connect()
    sys.waitUntil("mqtt_conack")
    while true do
        -- 演示等待其他task发送过来的上报信息
        -- local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        -- if ret then
        --     -- 提供关闭本while循环的途径, 不需要可以注释掉
        --     -- if topic == "close" then
        --     --     break
        --     -- end
        --     mqttc:publish(topic, data, qos)
        -- end
        -- 如果没有其他task上报, 可以写个空等待
        -- sys.wait(60000000)
        if mqttc and mqttc:ready() then
            local pkgid = mqttc:publish(pub_topic .. "telemetry", "message from " .. imei .. " on " .. os.date(), 0)
        end
        sys.wait(60 * 1000)
    end
    mqttc:close()
    mqttc = nil
end)

return mqtt_service