local nemopi = {}

local utils = require("utils")
local modbus = require("modbus")
local power = require("power")
local sensors = require("sensors")

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(- #ending) == ending
end

local mqtt_host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net"
local mqtt_port = 8883
local imei = mobile.imei()
local pub_topic = "buoys/" .. imei .. "/d2c"
local sub_topic = "buoys/" .. imei .. "/c2d"

local mqttc = nil

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
            log.warn("reboot!!!")
            rtos.reboot()
        elseif cmd == "CREDENTIALS" then
            local url = args[1]
            if url == nil then
                log.error("sms", "cred", "missing url")
                return
            end
            if not starts_with(url, "http://") and not starts_with(url, "https://") then
                log.error("sms", "cred", "invalid url")
                return
            end
            -- http client works in task
            sys.taskInit(function()
                sys.wait(1000)
                local code, _, body = http.request("GET", url).wait()
                if code == 200 then
                    local creds = json.decode(body)
                    utils.fskv_set_credentials(creds)
                    utils.handle_error(1000)
                end
            end)
        end
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
    socket.sntp({ "0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com" }, socket.LWIP_GP)
    local ret = sys.waitUntil("NTP_UPDATE", 180 * 1000) -- 3 mins
    if not ret then
        log.error("ntp", "failed")
        utils.handle_error()
    end
    log.info("ntp", "ready")

    -- get credentials
    utils.fskv_setup()
    local ret, credentials = utils.fskv_get_credentials()
    if not ret then
        log.error("mqtt", "failed to get mqtt credentials")
        utils.handle_error(30 * 60 * 1000)
    end

    -- setup mqtt
    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, {
        client_cert = credentials["cert"],
        client_key = credentials["key"],
        verify = 0
    })
    mqttc:auth(imei, credentials["username"], credentials["password"], true) -- client_id must have value, the last parameter true is for clean session
    mqttc:keepalive(60)                                                      -- default value 240s
    mqttc:autoreconn(true, 3000)                                             -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures
    mqttc:debug(false)

    mqttc:on(function(mqtt_client, event, topic, payload)
        if event == "conack" then
            mqttc:subscribe(sub_topic .. "/#")
            local telemetry = {
                msg_type = "connect",
                imei = imei,
            }
            mqttc:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
            -- elseif event == "recv" then
            --     if ends_with(topic, "cmd") then
            --         local cb = function(msg)
            --             mqttc:publish(pub_topic .. "/cmd", msg, 0)
            --         end
            --         system_service.system_call(cb, payload)
            --     end
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
        local telemetry = {
            msg_type = "detect",
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

    sys.wait(2000)
    power.internal.disable()
    power.external.disable()

    sys.wait(2000)

    while 1 do
        -- #######################################################################
        -- telemetry
        -- #######################################################################
        power.internal.enable()
        power.external.enable()
        sys.wait(10 * 1000)
        do
            for index, sensor in ipairs(detected_sensors) do
                log.info("main", "run", "index", index)
                local info = sensor:info()
                local data = sensor:run()

                local telemetry = {
                    msg_type = "read",
                    model = info.model,
                    interface = info.interface,
                    address = info.address,
                    data = data
                }
                mqttc:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
            end
        end

        sys.wait(2 * 1000)
        power.internal.disable()
        power.external.disable()
        -- #######################################################################

        sys.wait(2 * 1000)

        -- #######################################################################
        -- diagnose
        -- #######################################################################
        power.internal.enable()
        sys.wait(1 * 1000)

        do
            local vbat = power.internal.vbat()

            local telemetry = {
                msg_type = "diagnose",
                vbat = vbat,
            }
            mqttc:publish(pub_topic .. "/telemetry", json.encode(telemetry), 0)
        end

        sys.wait(1 * 1000)
        power.internal.disable()
        -- #######################################################################

        sys.wait(60 * 60 * 1000)
    end
end)

return nemopi
