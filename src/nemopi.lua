local nemopi = {}

local communication = require("communication")
local utils = require("utils")
local modbus = require("modbus")
local power = require("power")
local sensors = require("sensors")
local led = require("led")

local imei = mobile.imei()

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

local function seralise_payload(msg_type, body)
    local telemetry = body
    telemetry["msg_type"] = msg_type
    return json.encode(telemetry)
end

local function seralise_response_payload(cmd, operation_id, status, reason)
    if type(operation_id) ~= "string" and type(operation_id) ~= "number" then
        operation_id = nil
    end
    local payload = {
        msg_type = "response",
        cmd = cmd,
        operation_id = operation_id,
        status = status,
        reason = reason
    }
    return json.encode(payload)
end

local function process_command(sub_topic, payload, response_topic)

    local telemetry, result, err = json.decode(payload)
    
    if telemetry == nil or result ~= 1 then
        log.error("process_command", "json decode", "failed", err)
        communication.publish(response_topic, seralise_response_payload(nil, nil, "failed", "json decode failed"))
        return
    end
    
    if telemetry["msg_type"] ~= "cmd" or type(telemetry["cmd"]) ~= "string" then
        log.error("process_command", "msg_type", telemetry["msg_type"], "cmd", telemetry["cmd"], "unknown")
        communication.publish(response_topic, seralise_response_payload(nil, nil, "failed", "msg_type or cmd unknown"))
        return
    end

    log.info("process_command", "msg_type", telemetry["msg_type"], "cmd", telemetry["cmd"], "operation_id", telemetry["operation_id"])
    
    if telemetry["cmd"] == "ota" then
        log.info("process_command", "run ota")
        utils.ota(telemetry["url"])
        communication.publish(response_topic, seralise_response_payload("ota", telemetry["operation_id"], "ok", nil))
    elseif telemetry["cmd"] == "reboot" then
        log.info("process_command", "reboot")
        communication.publish(response_topic, seralise_response_payload("reboot", telemetry["operation_id"], "ok", nil))
        utils.reboot_with_delay_nonblocking(60 * 1000)
    elseif telemetry["cmd"] == "ping" then
        log.info("process_command", "ping")
        communication.publish(response_topic, seralise_response_payload("ping", telemetry["operation_id"], "ok", nil))
    else 
        log.info("process_command", "cmd", telemetry["cmd"], "unknown")
        payload = {
            cmd = telemetry["cmd"],
            operation_id = telemetry["operation_id"],
            reason = "cmd unknown",
            status = "failed"
        }
        communication.publish(response_topic, seralise_response_payload(telemetry["cmd"], telemetry["operation_id"], "failed", "cmd unknown"))
    end
end

sys.taskInit(function()
    assert(crypto.cipher_suites, "firmware missing crypto.cipher_suites support")
    assert(mqtt, "firmware missing mqtt support")
    assert(fskv, "firmware missing fskv support")

    sms_setup()
    fskv_setup()

    led.setMode(led.WAIT_FOR_NETWORK)
    
    -- communication module setup
    --[[
        cloud to device topics: 
        - buoys/<imei>/c2d/cmd

        device to cloud topics:
        - buoys/<imei>/d2c/telemetry
        - buoys/<imei>/d2c/response
    ]]
    local device_id = imei
    local sub_topics = {
        "buoys/" .. device_id .. "/c2d/#",
    }
    local telemetry_pub_topic = "buoys/" .. imei .. "/d2c/telemetry"
    local response_pub_topic = "buoys/" .. imei .. "/d2c/response"
    if not communication.init(device_id, sub_topics) then
        log.error("communication", "init", "failed")
        utils.reboot_with_delay_blocking(30 * 60 * 1000)
    end

    -- led.setMode(led.NETWORK_CONNECTED)
    led.setMode(led.MQTT_CONNECTED)

    -- send connect telemetry
    local payload = {
        imei = imei,
        firmware = rtos.firmware(),
        version = VERSION,
        ticks = mcu.ticks(),
        power_on_reason = {pm.lastReson()},
    }
    communication.publish(telemetry_pub_topic, seralise_payload("connect", payload))

    -- request configuration 
    -- TODO: request and wait for configuration 

    -- fallback to old configuration method 
    -- load system configuration
    local ret, config = utils.fskv_get_config()
    if not ret then
        log.error("config", "failed to read system config")
        log.warn("config", "fallback to default config")
        config = {
            read_interval_ms = 30 * 60 * 1000,
        }
        assert(utils.fskv_set_config(config), "failed to set config")
    end

    -- listen to commands 
    sys.subscribe("MQTT_RECV", function(topic, payload)
        sys.taskInit(process_command, topic, payload, response_pub_topic)
    end)


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

        communication.publish(telemetry_pub_topic, seralise_payload("detect", payload))
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
            communication.publish(telemetry_pub_topic, seralise_payload("diagnosis", payload))
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
            communication.publish(telemetry_pub_topic, seralise_payload("data", payload))
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
