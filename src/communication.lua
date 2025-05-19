local communication = {}

--[[
    Communication Module
    
    WARNING: Only one instance of communication module is allowed
]]

communication.mqtt_client = nil

local function network_setup()
    rtc.timezone(0)
    -- mobile.setAuto(check_sim_period, get_cell_period, search_cell_time, auto_reset_stack, network_check_period)
    mobile.setAuto(10 * 1000, 5 * 60 * 1000, 5, true, 5 * 60 * 1000)
    socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

    -- ip connection with 5 minutes timeout
    log.debug("communication", "ip", "wait")
    if not sys.waitUntil("IP_READY", 5 * 60 * 1000) then
        log.error("communication", "ip", "timeout")
        return false
    end
    log.debug("communication", "ip", "ready")

    -- ntp setup with 3 minutes timeout
    log.debug("communication", "ntp", "wait")
    socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"})
    if not sys.waitUntil("NTP_UPDATE", 3 * 60 * 1000) then
        log.error("communication", "ntp", "failed")
        return false
    end
    log.debug("communication", "ntp", "ready")

    -- TODO: add network check
    -- TODO: handle network disconnection

    return true
end

local function mqtt_validate_credentials(credentials)
    if type(credentials["username"]) ~= "string" or type(credentials["password"]) ~= "string" or
        type(credentials["cert"]) ~= "string" or type(credentials["key"]) ~= "string" or type(credentials["host"]) ~=
        "string" or type(credentials["port"]) ~= "number" or type(credentials["client_id"]) ~= "string" then
        log.error("communication", "mqtt", "validate_credentials", "invalid credentials")
        return false
    end
    return true
end

local function mqtt_request_credentials(device_id)
    assert(device_id ~= nil and type(device_id) == "string" and device_id ~= "", "device_id must be a string")

    log.debug("communication", "mqtt", "request_credentials")

    local code, headers, body = http.request("POST", "https://issuer.nemopi.com/api/certificate", {}, json.encode({
        imei = device_id
    })).wait()
    log.debug("communication", "mqtt", "request_credentials", "received", "code", code)
    if code == 200 then
        local parsed = json.decode(body)
        local credentials = {
            host = "nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net",
            port = 8883,
            client_id = device_id,
            username = device_id,
            password = "",
            cert = parsed["certificate"],
            key = parsed["privateKey"]
        }
        if mqtt_validate_credentials(credentials) then
            log.debug("communication", "mqtt", "request_credentials", "success")
            return credentials
        end
    end
    log.error("communication", "mqtt", "request_credentials", "failed", "code", code, "body", body)

    return nil
end

local function mqtt_get_credentials(device_id)
    local credentials = fskv.get("credentials")
    if credentials and mqtt_validate_credentials(credentials) then
        log.debug("communication", "mqtt", "get_credentials", "from fskv")
        return credentials
    end
    credentials = mqtt_request_credentials(device_id)
    if credentials and mqtt_validate_credentials(credentials) then
        log.debug("communication", "mqtt", "get_credentials", "from request")
        fskv.set("credentials", credentials) -- store new credentials in fskv
        return credentials
    end
    log.error("communication", "mqtt", "get_credentials", "failed")
    return nil
end

local function mqtt_create_client(credentials, sub_topics)
    local mqtt_client = mqtt.create(nil, credentials["host"], credentials["port"], {
        client_cert = credentials["cert"],
        client_key = credentials["key"],
        verify = 0
    })
    assert(mqtt_client, "failed to create mqtt client")

    mqtt_client:auth(credentials["client_id"], credentials["username"], credentials["password"], true) -- client_id must have value, the last parameter true is for clean session
    mqtt_client:keepalive(60) -- default value 240s
    mqtt_client:autoreconn(true, 3000) -- auto reconnect -- may need to move to custom implementation later, like restart hw after a couple of failures
    mqtt_client:debug(false)
    mqtt_client:on(function(mqtt_client, event, topic, payload)
        if event == "conack" then
            for i, sub_topic in ipairs(sub_topics) do
                assert(sub_topic ~= nil and type(sub_topic) == "string" and sub_topic ~= "", "sub_topics must be a string")
                mqtt_client:subscribe(sub_topic)
            end
            sys.publish("MQTT_CONNECTED")
        elseif event == "recv" then
            -- forward to internal callback
            sys.publish("MQTT_RECV", topic, payload)
        elseif event == "sent" then
            sys.publish("MQTT_SENT")
        elseif event == "disconnect" then
            -- no operation
            -- TODO: add disconnection countdown
        end
    end)

    return mqtt_client
end

function communication.init(device_id, sub_topics)

    assert(device_id ~= nil and type(device_id) == "string" and device_id ~= "", "device_id must be a string")
    assert(sub_topics ~= nil and type(sub_topics) == "table", "sub_topics is a list of strings")

    assert(communication.mqtt_client == nil, "communication module can only be initialized once")

    log.info("communication", "network_setup")
    if not network_setup() then
        log.error("communication", "network_setup", "failed")
        return false
    end

    log.info("communication", "mqtt_get_credentials")
    local credentials = mqtt_get_credentials(device_id)
    if not credentials then
        log.error("communication", "mqtt_get_credentials", "failed")
        return false
    end

    log.info("communication", "mqtt create client")
    communication.mqtt_client = mqtt_create_client(credentials, sub_topics)

    log.info("communication", "mqtt connect")
    communication.mqtt_client:connect()
    if not sys.waitUntil("MQTT_CONNECTED", 60 * 1000) then
        log.error("communication", "mqtt connect", "timeout")
        return false
    end

    return true
end

function communication.publish(topic, payload)
    assert(communication.mqtt_client ~= nil, "communication module not initialized")
    assert(topic ~= nil and type(topic) == "string" and topic ~= "", "topic must be a string")
    assert(payload ~= nil and type(payload) == "string" and payload ~= "", "payload must be a string")

    communication.mqtt_client:publish(topic, payload, 1)
    -- sys.waitUntil("MQTT_SENT", 60 * 1000)
    -- if not sys.waitUntil("MQTT_SENT", 60 * 1000) then
    --     log.error("communication", "publish", "timeout")
    --     return false
    -- end
    return true
end

return communication
