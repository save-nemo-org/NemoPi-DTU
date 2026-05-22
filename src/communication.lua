local communication = {}

--[[
    Communication Module

    Owns the single MQTT client. Credentials (including the dynamic broker hostname)
    are obtained from the device-provisioning service via `src/provisioning.lua`.

    WARNING: Only one instance of communication module is allowed.
]]

local provisioning = require("provisioning")

communication.mqtt_client = nil

local function network_setup()
    rtc.timezone(0)
    -- mobile.setAuto(check_sim_period, get_cell_period, search_cell_time, auto_reset_stack, network_check_period)
    mobile.setAuto(10 * 1000, 5 * 60 * 1000, 5, true, 5 * 60 * 1000)
    socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

    log.debug("communication", "ip", "wait")
    if not sys.waitUntil("IP_READY", 5 * 60 * 1000) then
        log.error("communication", "ip", "timeout")
        return false
    end
    log.debug("communication", "ip", "ready")

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
    if type(credentials) ~= "table"
        or type(credentials.host) ~= "string" or #credentials.host == 0
        or type(credentials.port) ~= "number"
        or type(credentials.client_id) ~= "string" or #credentials.client_id == 0
        or type(credentials.username) ~= "string"
        or type(credentials.password) ~= "string"
        or type(credentials.cert) ~= "string" or #credentials.cert == 0
        or type(credentials.key) ~= "string" or #credentials.key == 0 then
        log.error("communication", "mqtt_validate_credentials", "invalid credentials")
        return false
    end
    return true
end

local function mqtt_create_client(credentials, sub_topics)
    local mqtt_client = mqtt.create(nil, credentials.host, credentials.port, {
        client_cert = credentials.cert,
        client_key = credentials.key,
        verify = 0
    })
    assert(mqtt_client, "failed to create mqtt client")

    mqtt_client:auth(credentials.client_id, credentials.username, credentials.password, true)
    mqtt_client:keepalive(60)
    mqtt_client:autoreconn(true, 3000)
    mqtt_client:debug(false)
    mqtt_client:on(function(mqtt_client, event, topic, payload)
        if event == "conack" then
            for _, sub_topic in ipairs(sub_topics) do
                assert(type(sub_topic) == "string" and #sub_topic > 0, "sub_topics must be non-empty strings")
                mqtt_client:subscribe(sub_topic)
            end
            sys.publish("MQTT_CONNECTED")
        elseif event == "recv" then
            sys.publish("MQTT_RECV", topic, payload)
        elseif event == "sent" then
            sys.publish("MQTT_SENT")
        elseif event == "disconnect" then
            -- TODO: add disconnection countdown
        end
    end)

    return mqtt_client
end

-- Build + connect an MQTT client from `credentials`. Returns true on CONNACK,
-- false on validation failure / timeout. Best-effort closes a previous client
-- if one was left over from a failed first attempt.
local function try_mqtt_connect(credentials, sub_topics)
    if communication.mqtt_client then
        pcall(function() communication.mqtt_client:close() end)
        communication.mqtt_client = nil
    end

    if not mqtt_validate_credentials(credentials) then
        return false
    end

    log.info("communication", "mqtt create client", "host", credentials.host, "port", credentials.port)
    communication.mqtt_client = mqtt_create_client(credentials, sub_topics)

    log.info("communication", "mqtt connect")
    communication.mqtt_client:connect()
    if sys.waitUntil("MQTT_CONNECTED", 60 * 1000) then
        return true
    end
    log.error("communication", "mqtt connect", "timeout")
    pcall(function() communication.mqtt_client:close() end)
    communication.mqtt_client = nil
    return false
end

--[[
    Two-attempt boot:
      1. Try whatever's in the fskv cache (no HTTP). Covers the steady-state
         warm boot where nothing has changed since the last successful run.
      2. On failure (or empty cache), fall through to fresh provisioning —
         that calls /onboard and, if no cert is cached, /certificate.

    We deliberately do NOT auto-invalidate the cached cert on MQTT failure:
      - A network blip would burn the cert for no reason, and
      - /certificate is one-shot per IMEI (server flips
        allowCertificateIssuance=false after first success), so a needless
        invalidate can wedge the device permanently if the next request 400s.
    If the cert is genuinely bad (broker rejects the thumbprint), /onboard
    will eventually 403 too and the device just keeps sleeping 30 min between
    attempts until an admin resets the row.
]]
function communication.init(device_id, sub_topics)
    assert(type(device_id) == "string" and #device_id > 0, "device_id must be a string")
    assert(type(sub_topics) == "table", "sub_topics is a list of strings")

    log.info("communication", "network_setup")
    if not network_setup() then
        log.error("communication", "network_setup", "failed")
        return false
    end

    -- Attempt 1: cached creds, no HTTP.
    local credentials = provisioning.load_cached_credentials(device_id)
    if credentials then
        log.info("communication", "attempt 1: cached credentials")
        if try_mqtt_connect(credentials, sub_topics) then
            return true
        end
        log.warn("communication", "cached credentials didn't connect, falling through to fresh provisioning")
    else
        log.info("communication", "no cached credentials, going straight to provisioning")
    end

    -- Attempt 2: fresh /onboard (and /certificate if cert wasn't cached).
    log.info("communication", "attempt 2: provisioning.get_credentials")
    credentials = provisioning.get_credentials(device_id, {
        os = "LuatOS",
        firmwareVersion = VERSION,
    })
    if not credentials then
        log.error("communication", "provisioning.get_credentials", "failed")
        return false
    end
    if try_mqtt_connect(credentials, sub_topics) then
        return true
    end
    log.error("communication", "fresh credentials didn't connect either")
    return false
end

function communication.publish(topic, payload)
    assert(communication.mqtt_client ~= nil, "communication module not initialized")
    assert(type(topic) == "string" and #topic > 0, "topic must be a non-empty string")
    assert(type(payload) == "string" and #payload > 0, "payload must be a non-empty string")

    communication.mqtt_client:publish(topic, payload, 1)
    return true
end

return communication
