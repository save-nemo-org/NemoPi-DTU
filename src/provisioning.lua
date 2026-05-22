local provisioning = {}

--[[
    Device Provisioning Module — Zero-Touch Provisioning (ZTP) client.

    Implements the three-step onboarding API at https://provisioning.nemopi.com/api/:

      1. POST /certificate          → obtain long-lived device cert + private key (once per device)
      2. POST /onboard              → request MQTT broker assignment
      3. GET  /onboard/{id}         → poll if onboarding returned `pending`

    See https://github.com/save-nemo-org/device-provisioning for the server-side spec.

    Persisted fskv keys:
      cert_b64        — device certificate (base64, no PEM headers; PEM-wrapped before use)
      key_b64         — device private key (base64, no PEM headers; PEM-wrapped before use)
      cert_expiry     — ISO 8601 expiry of the cached certificate (informational)
      cert_thumbprint — SHA-1 thumbprint returned by /certificate (informational)
      mqtt_host       — hostname returned by latest succeeded /onboard
]]

local PROVISIONING_API = "https://provisioning.nemopi.com/api"
local MQTT_PORT = 8883
local ONBOARD_POLL_INTERVAL_MS = 5 * 1000
local ONBOARD_POLL_MAX_ATTEMPTS = 12        -- 12 * 5s = 60s

-- ============================================================
-- PEM helpers
-- ============================================================

-- Wrap a single-line base64 string with PEM header/footer and 64-char line breaks.
-- LuatOS mqtt expects PEM-formatted cert and key; the provisioning service returns
-- the same payload as base64 with the PEM headers stripped.
local function wrap_pem(b64, label)
    if type(b64) ~= "string" or #b64 == 0 then return nil end
    local lines = {}
    for i = 1, #b64, 64 do
        table.insert(lines, b64:sub(i, i + 63))
    end
    return "-----BEGIN " .. label .. "-----\n"
        .. table.concat(lines, "\n")
        .. "\n-----END " .. label .. "-----\n"
end

function provisioning.cert_pem(cert_b64)
    return wrap_pem(cert_b64, "CERTIFICATE")
end

function provisioning.key_pem(key_b64)
    return wrap_pem(key_b64, "PRIVATE KEY")
end

-- ============================================================
-- REST calls
-- ============================================================

-- Returns: {cert_b64, key_b64, thumbprint, expiry} on success, nil on failure.
local function request_certificate(imei)
    local url = PROVISIONING_API .. "/certificate"
    log.info("provisioning", "POST", url, "imei", imei)
    local code, _, body = http.request("POST", url,
        {["Content-Type"] = "application/json"},
        json.encode({imei = imei})
    ).wait()

    -- IMPORTANT: never log `body` from /certificate responses — even malformed
    -- ones can carry the unencrypted private key. Log byte counts + parsed
    -- structure hints instead.
    local body_len = (type(body) == "string") and #body or -1

    if code == 200 then
        local parsed = json.decode(body or "")
        if type(parsed) ~= "table"
            or type(parsed.certificate) ~= "string"
            or type(parsed.privateKey) ~= "string" then
            log.error("provisioning", "request_certificate",
                "malformed 200 body (suppressed; may contain private key)",
                "bytes", body_len)
            return nil
        end
        log.info("provisioning", "request_certificate", "ok", "expiry", parsed.expiry, "thumbprint", parsed.thumbprint)
        return {
            cert_b64 = parsed.certificate,
            key_b64 = parsed.privateKey,
            thumbprint = parsed.thumbprint,
            expiry = parsed.expiry,
        }
    end

    -- Non-200 bodies are server error messages (no key material), but for
    -- defence in depth we still only surface the parsed `.error` field
    -- rather than echoing the raw body.
    local err = "unknown"
    if body then
        local parsed = json.decode(body)
        if type(parsed) == "table" and type(parsed.error) == "string" then
            err = parsed.error
        end
    end
    if code == 429 then
        log.error("provisioning", "request_certificate", "rate limited (429); 1 req/min/IP", err)
    elseif code == 400 then
        log.error("provisioning", "request_certificate", "rejected (400)", err)
    else
        log.error("provisioning", "request_certificate", "http", code, "error", err, "bytes", body_len)
    end
    return nil
end

-- Returns the full operation response {id, status, result, error} or nil on transport failure.
local function request_onboarding(imei, cert_b64, metadata)
    local url = PROVISIONING_API .. "/onboard"
    log.info("provisioning", "POST", url, "deviceId", imei)
    local code, _, body = http.request("POST", url,
        {
            ["Content-Type"] = "application/json",
            ["X-Client-Cert"] = cert_b64,
        },
        json.encode({deviceId = imei, metadata = metadata or {}})
    ).wait()

    if code ~= 200 then
        log.error("provisioning", "request_onboarding", "http", code, "body", body)
        -- The server returns a structured OperationResponse even on 4xx; try to parse it
        -- so callers can surface `error` rather than guessing from the code.
        local parsed = body and json.decode(body) or nil
        if type(parsed) == "table" then return parsed end
        return nil
    end

    local parsed = json.decode(body or "")
    if type(parsed) ~= "table" or type(parsed.status) ~= "string" then
        log.error("provisioning", "request_onboarding", "malformed 200 body", body)
        return nil
    end
    log.info("provisioning", "request_onboarding", "status", parsed.status, "id", parsed.id)
    return parsed
end

-- Poll /onboard/{id} until a terminal status is reached, or attempts exhausted.
-- Returns the final operation response or nil on timeout/transport failure.
local function poll_onboarding(operation_id, cert_b64)
    local url = PROVISIONING_API .. "/onboard/" .. operation_id

    for attempt = 1, ONBOARD_POLL_MAX_ATTEMPTS do
        sys.wait(ONBOARD_POLL_INTERVAL_MS)
        log.debug("provisioning", "GET", url, "attempt", attempt, "of", ONBOARD_POLL_MAX_ATTEMPTS)
        local code, _, body = http.request("GET", url,
            {["X-Client-Cert"] = cert_b64}
        ).wait()

        if code == 200 then
            local parsed = json.decode(body or "")
            if type(parsed) == "table" and type(parsed.status) == "string" then
                log.info("provisioning", "poll_onboarding", "status", parsed.status)
                if parsed.status ~= "pending" then
                    return parsed -- succeeded, failed, or canceled
                end
            else
                log.error("provisioning", "poll_onboarding", "malformed 200 body", body)
            end
        else
            log.error("provisioning", "poll_onboarding", "http", code, "body", body)
        end
    end

    log.error("provisioning", "poll_onboarding", "timed out after", ONBOARD_POLL_MAX_ATTEMPTS, "attempts")
    return nil
end

-- ============================================================
-- Orchestration
-- ============================================================

-- Returns cached or freshly issued {cert_b64, key_b64}. nil on failure.
local function get_or_issue_certificate(imei)
    local cert_b64 = fskv.get("cert_b64")
    local key_b64 = fskv.get("key_b64")
    if type(cert_b64) == "string" and #cert_b64 > 0
        and type(key_b64) == "string" and #key_b64 > 0 then
        log.info("provisioning", "get_or_issue_certificate", "using cached cert")
        return {cert_b64 = cert_b64, key_b64 = key_b64}
    end

    local issued = request_certificate(imei)
    if not issued then return nil end

    -- Persist before returning so a crash between /certificate and /onboard doesn't burn
    -- the IMEI's one-shot certificate issuance (the server sets allowCertificateIssuance=false
    -- after the first successful response).
    fskv.set("cert_b64", issued.cert_b64)
    fskv.set("key_b64", issued.key_b64)
    if issued.expiry then fskv.set("cert_expiry", issued.expiry) end
    if issued.thumbprint then fskv.set("cert_thumbprint", issued.thumbprint) end
    log.info("provisioning", "get_or_issue_certificate", "stored new certificate")
    return {cert_b64 = issued.cert_b64, key_b64 = issued.key_b64}
end

-- Returns the assigned mqtt broker hostname (string). nil on failure.
local function resolve_mqtt_endpoint(imei, cert_b64, metadata)
    local response = request_onboarding(imei, cert_b64, metadata)
    if not response then return nil end

    if response.status == "pending" then
        if type(response.id) ~= "string" then
            log.error("provisioning", "resolve_mqtt_endpoint", "pending without operation id")
            return nil
        end
        response = poll_onboarding(response.id, cert_b64)
        if not response then return nil end
    end

    if response.status ~= "succeeded" then
        log.error("provisioning", "resolve_mqtt_endpoint",
            "terminal status", response.status, "error", response.error)
        return nil
    end

    if type(response.result) ~= "table" or type(response.result.endpoints) ~= "table" then
        log.error("provisioning", "resolve_mqtt_endpoint", "no endpoints in succeeded result")
        return nil
    end
    for _, ep in ipairs(response.result.endpoints) do
        if type(ep) == "table" and ep.kind == "mqtt" and type(ep.hostname) == "string" then
            log.info("provisioning", "resolve_mqtt_endpoint", "mqtt", ep.hostname)
            fskv.set("mqtt_host", ep.hostname)
            return ep.hostname
        end
    end
    log.error("provisioning", "resolve_mqtt_endpoint", "no mqtt endpoint in result")
    return nil
end

--[[
    Returns a credentials table ready for `mqtt.create` and `mqtt:auth`:
        {host, port, client_id, username, password, cert, key}
    or nil on any unrecoverable failure (logged at source).
]]
--[[
    Build a credentials struct from the fskv cache alone — no HTTP calls.
    Returns nil if any of cert_b64 / key_b64 / mqtt_host is missing or empty.

    This is the fast path on warm boots: communication.lua tries the cached
    credentials first and only falls back to `get_credentials` (which hits
    /onboard and possibly /certificate) if the cached attempt doesn't make
    it through MQTT.
]]
function provisioning.load_cached_credentials(imei)
    assert(type(imei) == "string" and #imei > 0, "imei must be non-empty string")

    local cert_b64 = fskv.get("cert_b64")
    local key_b64 = fskv.get("key_b64")
    local mqtt_host = fskv.get("mqtt_host")
    if type(cert_b64) ~= "string" or #cert_b64 == 0 then return nil end
    if type(key_b64)  ~= "string" or #key_b64  == 0 then return nil end
    if type(mqtt_host) ~= "string" or #mqtt_host == 0 then return nil end

    return {
        host = mqtt_host,
        port = MQTT_PORT,
        client_id = imei,
        username = imei,
        password = "",
        cert = provisioning.cert_pem(cert_b64),
        key = provisioning.key_pem(key_b64),
    }
end


function provisioning.get_credentials(imei, metadata)
    assert(type(imei) == "string" and #imei > 0, "imei must be non-empty string")

    local cert = get_or_issue_certificate(imei)
    if not cert then return nil end

    local mqtt_host = resolve_mqtt_endpoint(imei, cert.cert_b64, metadata)
    if not mqtt_host then return nil end

    return {
        host = mqtt_host,
        port = MQTT_PORT,
        client_id = imei,
        username = imei,
        password = "",
        cert = provisioning.cert_pem(cert.cert_b64),
        key = provisioning.key_pem(cert.key_b64),
    }
end

return provisioning
