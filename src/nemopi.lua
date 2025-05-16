local nemopi = {}

local utils = require("utils")
local modbus = require("modbus")
local power = require("power")
local sensors = require("sensors")
local led = require("led")

local imei = mobile.imei()
local pub_topic = "buoys/" .. imei .. "/d2c"
local sub_topic = "buoys/" .. imei .. "/c2d"

local function sms_setup()
    sms.setNewSmsCb(function(num, txt, metas)
        -- parse str into cmd and args
        local iter = string.gmatch(txt, "%S+")
        local cmd = iter()
        local args = {}
        for arg in iter do
            table.insert(args, arg)
        end
        -- process
        if cmd == "PING" then
            sms.send(num, "OK", false)
        elseif cmd == "REBOOT" then
            sms.send(num, "OK", false)
            utils.reboot_with_delay_nonblocking(60 * 1000)
        elseif cmd == "OTA" then
            utils.ota(args[1])
        end
    end)
end

local function network_setup()
    rtc.timezone(0)
    -- mobile.setAuto(check_sim_period, get_cell_period, search_cell_time, auto_reset_stack, network_check_period)
    mobile.setAuto(10 * 1000, 5 * 60 * 1000, 5, true, 5 * 60 * 1000)
    socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

    log.info("ip", "wait")
    local ret = sys.waitUntil("IP_READY", 3 * 60 * 1000) -- 3 mins
    if not ret then
        log.error("ip", "timeout")
        utils.reboot_with_delay_blocking()
    end
    log.info("ip", "ready")
    led.setMode(led.WAIT_FOR_NETWORK)

    socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"})
    local ret = sys.waitUntil("NTP_UPDATE", 180 * 1000) -- 3 mins
    if not ret then
        log.error("ntp", "failed")
        utils.reboot_with_delay_blocking()
    end
    log.info("ntp", "ready")
    led.setMode(led.NETWORK_CONNECTED)
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
            log.debug("fskv", "key", k)
        end
    end
end

local function mqtt_validate_credentials(credentials)
    if type(credentials["username"]) ~= "string" 
    or type(credentials["password"]) ~= "string" 
    or type(credentials["cert"]) ~= "string" 
    or type(credentials["key"]) ~= "string" 
    or type(credentials["host"]) ~= "string"
    or type(credentials["port"]) ~= "number"
    or type(credentials["client_id"]) ~= "string" then
        log.error("mqtt", "validate_credentials", "invalid credentials")
        return false
    end
    return true
end

local function mqtt_request_credentials()
    log.info("mqtt", "request_credentials")

    local code, headers, body = http.request("POST", "https://issuer.nemopi.com/api/certificate", {}, json.encode({
        imei = imei
    })).wait()
    log.error("mqtt", "request_credentials", "received", "code", code)
    if code == 200 then
        local parsed = json.decode(body)
        local credentials = {
            host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net",
            port = 8883,
            client_id = imei,
            username = imei,
            password = "",
            cert = parsed["certificate"],
            key = parsed["privateKey"]
        }
        if mqtt_validate_credentials(credentials) then
            log.info("mqtt", "request_credentials", "success")
            return credentials
        end
    end
    log.error("mqtt", "request_credentials", "failed", "code", code, "body", body)
    sys.wait(60 * 1000) -- wait for 60 seconds

    return nil
end

local function mqtt_get_credentials()
    local credentials = fskv.get("credentials")
    if credentials and mqtt_validate_credentials(credentials) then
        log.info("mqtt", "get_credentials", "from fskv")
        return credentials
    end
    credentials = mqtt_request_credentials()
    if credentials then
        fskv.set("credentials", credentials)
        return credentials
    end
    return nil
end

local function mqtt_setup()
    local credentials = mqtt_get_credentials()
    if not credentials then
        log.error("mqtt", "failed to get mqtt credentials")
        utils.reboot_with_delay_blocking(30 * 60 * 1000)
    end
    local mqttc = mqtt.create(nil, credentials["host"], credentials["port"], {
        client_cert = credentials["cert"],
        client_key = credentials["key"],
        verify = 0
    })
    assert(mqttc, "failed to create mqtt client")

    mqttc:auth(credentials["client_id"], credentials["username"], credentials["password"], true) -- client_id must have value, the last parameter true is for clean session
    mqttc:keepalive(60) -- default value 240s
    mqttc:autoreconn(true, 3000) -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures
    mqttc:debug(false)

    return mqttc
end

local function sendTelemetry(client, msg_type, body)
    local telemetry = body
    telemetry["msg_type"] = msg_type
    client:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
end

sys.taskInit(function()
    assert(crypto.cipher_suites, "firmware missing crypto.cipher_suites support")
    assert(mqtt, "firmware missing mqtt support")
    assert(fskv, "firmware missing fskv support")

    sms_setup()
    network_setup()
    fskv_setup()

    local mqttc = mqtt_setup()

    mqttc:on(function(mqtt_client, event, topic, payload)
        if event == "conack" then
            mqttc:subscribe(sub_topic .. "/#")
            local payload = {
                imei = imei,
                firmware = rtos.firmware(),
                version = VERSION,
                ticks = mcu.ticks(),
                power_on_reason = {pm.lastReson()},
            }
            sendTelemetry(mqttc, "connect", payload)
        elseif event == "recv" then
            if topic:endsWith("/cmd") then
                local telemetry = json.decode(payload)
                if telemetry["msg_type"] == "config" then
                    local ret = utils.fskv_set_config(telemetry["config"])
                    if ret then
                        log.warn("c2d", "cmd", "config", "updated")
                        payload = {
                            cmd = "config",
                            status = "ok"
                        }
                        sendTelemetry(mqttc, "cmd", payload)
                    else
                        log.error("c2d", "cmd", "config", "failed to set config")
                        payload = {
                            cmd = "config",
                            status = "failed"
                        }
                        sendTelemetry(mqttc, "cmd", payload)
                    end
                elseif telemetry["msg_type"] == "ota" then
                    utils.ota(telemetry["url"])
                    payload = {
                        cmd = "ota",
                        status = "ok"
                    }
                    sendTelemetry(mqttc, "cmd", payload)
                    log.warn("c2d", "cmd", "ota", "okay")
                elseif telemetry["msg_type"] == "reboot" then
                    log.warn("c2d", "cmd", "reboot", "okay")
                    payload = {
                        cmd = "reboot",
                        status = "ok"
                    }
                    sendTelemetry(mqttc, "cmd", payload)
                    utils.reboot_with_delay_nonblocking(60 * 1000)
                elseif telemetry["msg_type"] == "ping" then
                    log.warn("c2d", "cmd", "ping", "okay")
                    local payload = {
                        cmd = "ping",
                        status = "ok"
                    }
                    sendTelemetry(mqttc, "cmd", payload)
                end
            end
        elseif event == "sent" then
            sys.publish("mqtt_sent")
        elseif event == "disconnect" then
            -- mqtt_client:connect()    -- required when autoreconn is false
        end
    end)

    -- connect mqtt
    log.info("mqtt", "connect", "wait")
    mqttc:connect()
    sys.waitUntil("mqtt_sent")
    log.info("mqtt", "connect", "ready")
    led.setMode(led.MQTT_CONNECTED)

    -- load system configuration
    local ret, config = utils.fskv_get_config()
    if not ret then
        log.error("config", "failed to read system config")
        utils.reboot_with_delay_blocking(30 * 60 * 1000)
    end
    assert(config, "invalid config")

    -- start sensoring task
    local UART_ID = 1
    local RS485_EN_GPIO = 25

    log.info("main", "setup")
    power.setup()
    modbus.enable(UART_ID, RS485_EN_GPIO)

    sys.wait(2 * 1000)

    power.internal.enable()
    power.external.enable()
    sys.wait(10 * 1000)

    local detected_sensors = {}
    do
        local payload = {
            sensors = {}
        }

        log.info("main", "detect")
        for name, sensor_class in pairs(sensors.sensor_classes) do
            log.info("main", "detect", name)
            local ret, detected = sensor_class:detect()
            if ret then
                log.info("main", "detected", name)
                table.insert(detected_sensors, detected)
                table.insert(payload.sensors, detected:info())
            end
        end

        sendTelemetry(mqttc, "detect", payload)
    end

    sys.wait(2000)
    power.internal.disable()
    power.external.disable()

    sys.wait(2000)

    while 1 do
        led.setMode(led.RUNNING)
        power.internal.enable()
        power.external.enable()
        sys.wait(10 * 1000)

        do
            local vbat = power.internal.vbat()
            local lat_lon = sensors.infrastructure.Gps:read()
            local cell = utils.cell_info()

            local payload = {
                vbat = vbat,
                lat_lon = lat_lon,
                cell = cell
            }
            sendTelemetry(mqttc, "diagnosis", payload)
        end

        do
            local payload = {
                sensors = {}
            }
            for index, sensor in ipairs(detected_sensors) do
                log.info("main", "run", "index", index)
                local info = sensor:info()
                local data = sensor:run()
                local sensor_telemetry = {
                    model = info.model,
                    interface = info.interface,
                    address = info.address,
                    data = data
                }
                table.insert(payload.sensors, sensor_telemetry)
            end
            sendTelemetry(mqttc, "data", payload)
        end

        sys.wait(2 * 1000)
        power.internal.disable()
        power.external.disable()
        led.setMode(led.MQTT_CONNECTED)

        log.info("lua", rtos.meminfo("lua"))
        log.info("sys", rtos.meminfo("sys"))

        sys.wait(config["read_interval_ms"])
    end
end)

return nemopi
