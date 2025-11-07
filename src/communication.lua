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

-- Validate certificate data (cert and key only)
local function mqtt_validate_certificate(certificate)
    if type(certificate) ~= "table" then
        log.error("communication", "mqtt", "validate_certificate", "certificate must be a table")
        return false
    end
    if type(certificate["cert"]) ~= "string" or certificate["cert"] == "" then
        log.error("communication", "mqtt", "validate_certificate", "invalid cert")
        return false
    end
    if type(certificate["key"]) ~= "string" or certificate["key"] == "" then
        log.error("communication", "mqtt", "validate_certificate", "invalid key")
        return false
    end
    return true
end

-- Validate complete MQTT credentials (includes broker info)
local function mqtt_validate_credentials(credentials)
    if type(credentials) ~= "table" then
        log.error("communication", "mqtt", "validate_credentials", "credentials must be a table")
        return false
    end
    if type(credentials["username"]) ~= "string" or type(credentials["password"]) ~= "string" or
        type(credentials["cert"]) ~= "string" or type(credentials["key"]) ~= "string" or type(credentials["host"]) ~=
        "string" or type(credentials["port"]) ~= "number" or type(credentials["client_id"]) ~= "string" then
        log.error("communication", "mqtt", "validate_credentials", "invalid credentials")
        return false
    end
    return true
end

-- Request certificate from the new provisioning API (done once per device)
local function mqtt_request_certificate(device_id)
    assert(device_id ~= nil and type(device_id) == "string" and device_id ~= "", "device_id must be a string")

    log.debug("communication", "mqtt", "request_certificate")

    -- Certificate issuer endpoint - rate limited to 1 request per minute per IMEI
    local code, headers, body = http.request("POST", "https://provisioning.nemopi.com/api/certificate", {}, json.encode({
        imei = device_id
    })).wait()
    log.debug("communication", "mqtt", "request_certificate", "received", "code", code)
    
    if code == 200 then
        local parsed = json.decode(body)
        local certificate = {
            cert = parsed["certificate"],
            key = parsed["privateKey"]
        }
        if mqtt_validate_certificate(certificate) then
            log.debug("communication", "mqtt", "request_certificate", "success")
            return certificate
        end
    elseif code == 429 then
        log.error("communication", "mqtt", "request_certificate", "rate_limited")
    end
    log.error("communication", "mqtt", "request_certificate", "failed", "code", code, "body", body)

    return nil
end

-- Check onboarding status (poll until terminal state)
local function mqtt_poll_onboarding_status(operation_id, max_retries, retry_delay_ms)
    max_retries = max_retries or 12  -- default 12 retries (1 minute with 5s delay)
    retry_delay_ms = retry_delay_ms or 5000  -- default 5 second delay
    
    for attempt = 1, max_retries do
        log.debug("communication", "mqtt", "poll_onboarding_status", "attempt", attempt)
        
        local code, headers, body = http.request("GET", "https://provisioning.nemopi.com/api/onboard/" .. operation_id, {}, "").wait()
        log.debug("communication", "mqtt", "poll_onboarding_status", "received", "code", code)
        
        if code == 200 then
            local parsed = json.decode(body)
            local status = parsed["status"]
            
            if status == "succeeded" then
                log.debug("communication", "mqtt", "poll_onboarding_status", "succeeded")
                -- Return broker configuration
                if type(parsed["broker"]) == "table" and 
                   type(parsed["broker"]["host"]) == "string" and parsed["broker"]["host"] ~= "" and 
                   type(parsed["broker"]["port"]) == "number" then
                    return {
                        host = parsed["broker"]["host"],
                        port = parsed["broker"]["port"]
                    }
                end
            elseif status == "failed" or status == "canceled" then
                log.error("communication", "mqtt", "poll_onboarding_status", "terminal_failure", "status", status)
                return nil
            elseif status == "pending" then
                log.debug("communication", "mqtt", "poll_onboarding_status", "pending", "retry_in_ms", retry_delay_ms)
                sys.wait(retry_delay_ms)
                -- continue to next attempt
            else
                log.error("communication", "mqtt", "poll_onboarding_status", "unknown_status", "status", status)
                return nil
            end
        else
            log.error("communication", "mqtt", "poll_onboarding_status", "request_failed", "code", code, "body", body)
            sys.wait(retry_delay_ms)
            -- continue to next attempt
        end
    end
    
    log.error("communication", "mqtt", "poll_onboarding_status", "max_retries_reached")
    return nil
end

-- Request MQTT broker endpoint from the new provisioning API (done on each boot)
local function mqtt_request_broker_endpoint(device_id, certificate)
    assert(device_id ~= nil and type(device_id) == "string" and device_id ~= "", "device_id must be a string")
    assert(mqtt_validate_certificate(certificate), "valid certificate required")

    log.debug("communication", "mqtt", "request_broker_endpoint")

    -- Onboard endpoint - initiates device onboarding
    local code, headers, body = http.request("POST", "https://provisioning.nemopi.com/api/onboard", {}, json.encode({
        imei = device_id
    })).wait()
    log.debug("communication", "mqtt", "request_broker_endpoint", "received", "code", code)
    
    if code == 200 then
        local parsed = json.decode(body)
        local status = parsed["status"]
        local operation_id = parsed["operationId"]
        
        if status == "succeeded" then
            -- Onboarding completed immediately, extract broker info
            log.debug("communication", "mqtt", "request_broker_endpoint", "immediate_success")
            if type(parsed["broker"]) == "table" and 
               type(parsed["broker"]["host"]) == "string" and parsed["broker"]["host"] ~= "" and 
               type(parsed["broker"]["port"]) == "number" then
                return {
                    host = parsed["broker"]["host"],
                    port = parsed["broker"]["port"]
                }
            end
        elseif status == "pending" and type(operation_id) == "string" and operation_id ~= "" then
            -- Onboarding is pending, need to poll for status
            log.debug("communication", "mqtt", "request_broker_endpoint", "pending", "operation_id", operation_id)
            return mqtt_poll_onboarding_status(operation_id)
        elseif status == "failed" or status == "canceled" then
            log.error("communication", "mqtt", "request_broker_endpoint", "terminal_failure", "status", status)
        else
            log.error("communication", "mqtt", "request_broker_endpoint", "invalid_response", "status", status)
        end
    end
    log.error("communication", "mqtt", "request_broker_endpoint", "failed", "code", code, "body", body)

    return nil
end

-- Get or provision certificate (stored persistently, only requested once)
local function mqtt_get_certificate(device_id)
    local certificate = fskv.get("mqtt_certificate")
    if certificate and mqtt_validate_certificate(certificate) then
        log.debug("communication", "mqtt", "get_certificate", "from fskv")
        return certificate
    end
    
    certificate = mqtt_request_certificate(device_id)
    if certificate and mqtt_validate_certificate(certificate) then
        log.debug("communication", "mqtt", "get_certificate", "from request")
        fskv.set("mqtt_certificate", certificate)
        return certificate
    end
    
    log.error("communication", "mqtt", "get_certificate", "failed")
    return nil
end

-- Build complete credentials from certificate and broker info
local function mqtt_get_credentials(device_id)
    -- Step 1: Get or provision certificate (once per device)
    local certificate = mqtt_get_certificate(device_id)
    if not certificate then
        log.error("communication", "mqtt", "get_credentials", "failed to get certificate")
        return nil
    end
    
    -- Step 2: Request broker endpoint (on each boot)
    local broker = mqtt_request_broker_endpoint(device_id, certificate)
    if not broker then
        log.error("communication", "mqtt", "get_credentials", "failed to get broker endpoint")
        return nil
    end
    
    -- Step 3: Build complete credentials
    local credentials = {
        host = broker["host"],
        port = broker["port"],
        client_id = device_id,
        username = device_id,
        password = "",
        cert = certificate["cert"],
        key = certificate["key"]
    }
    
    if mqtt_validate_credentials(credentials) then
        log.debug("communication", "mqtt", "get_credentials", "success")
        return credentials
    end
    
    log.error("communication", "mqtt", "get_credentials", "failed validation")
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
