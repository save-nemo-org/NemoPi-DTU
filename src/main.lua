-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "mqttdemo"
VERSION = "1.0.0"

--[[
MQTT is an inbuilt lib, so user doesn't need to import it explicitly 
]]

-- Sys is a required lib 
_G.sys = require("sys")
-- MQTT application need this lib 
_G.sysplus = require("sysplus")

-- Air780E的AT固件默认会为开机键防抖, 导致部分用户刷机很麻烦
-- Disable power key debouncing 
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- if rtos.bsp() == "EC618" and pm and pm.WORK_MODE then
--     pm.power(pm.WORK_MODE, 1)
-- end

-- 自动低功耗, 轻休眠模式
-- Air780E支持uart唤醒和网络数据下发唤醒, 但需要断开USB,或者pm.power(pm.USB, false) 但这样也看不到日志了
-- Enable auto sleep
-- pm.request(pm.LIGHT)

-- Use UTC time 
rtc.timezone(0)

local system_service = require("system_service")
local sms_service = require("sms_service")

-- Read Modem IMEI --
local imei = mobile.imei()

-- Server config 
local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
local mqtt_port = 8883
local mqtt_ssl = {
    client_cert = io.readFile("/luadb/client.crt"),
    client_key = io.readFile("/luadb/client.key"),
    verify = 0
}
local client_id = imei
local user_name = "client"
local password = ""

local pub_topic = "/" .. imei .. "/pub/"
local sub_topic = "/" .. imei .. "/sub/"
local sub_topic_table = {
    [sub_topic .. "echo"] = 1,
    [sub_topic .. "cmd"] = 1
}

-- Setup NET LED --
local netLed = require("netLed")
local NETLED_PIN = 27
netLed.setup(true, NETLED_PIN, nil)

local mqttc = nil

-- Some utility function
local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

sys.taskInit(function()
    -- Print cipher_suites
    if crypto.cipher_suites then
        log.info("cipher", "suites", json.encode(crypto.cipher_suites()))
    else
        log.info("bsp", "crypto.cipher_suites is not supported in the BSP")
    end

    if mqtt == nil then
        while 1 do
            sys.wait(1000)
            log.info("bsp", "MQTT is not supported in the BSP")
        end
    end

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
            sys.publish("SOCKET_ACTIVE", true)
            mqtt_client:subscribe(sub_topic_table)
        elseif event == "recv" then
            log.info("mqtt", "downlink", "topic", topic, "payload", payload)
            if ends_with(topic, "cmd") then
                local mqtt_cb = function(msg)
                    mqttc:publish(pub_topic .. "cmd", msg, 1)
                end
                system_service.system_call(payload, mqtt_cb)
            end
            -- sys.publish("mqtt_payload", topic, payload)
        elseif event == "sent" then
            -- log.info("mqtt", "sent", "pkgid", data)
        elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
            sys.publish("SOCKET_ACTIVE", false)
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
        sys.wait(60000000)
    end
    mqttc:close()
    mqttc = nil
end)

-- 这里演示在另一个task里上报数据, 会定时上报数据,不需要就注释掉
sys.taskInit(function()
    sys.wait(3000)
    while true do
        sys.wait(60 * 1000)
        if mqttc and mqttc:ready() then
            local pkgid = mqttc:publish(pub_topic .. "telemetry", "message from " .. imei .. " on " .. os.date(), 1)
        end
    end
end)

-- -- 以下是演示与uart结合, 简单的mqtt-uart透传实现,不需要就注释掉
-- local uart_id = 1
-- uart.setup(uart_id, 9600)
-- uart.on(uart_id, "receive", function(id, len)
--     local data = ""
--     while 1 do
--         local tmp = uart.read(uart_id)
--         if not tmp or #tmp == 0 then
--             break
--         end
--         data = data .. tmp
--     end
--     log.info("uart", "uart收到数据长度", #data)
--     sys.publish("mqtt_pub", pub_topic, data)
-- end)
-- sys.subscribe("mqtt_payload", function(topic, payload)
--     log.info("uart", "uart发送数据长度", #payload)
--     uart.write(1, payload)
-- end)

-- End of User Code ---------------------------------------------
-- Start scheduler 
sys.run()
-- Don't program after sys.run()
