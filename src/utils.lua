local utils = {}

function utils.fskv_setup()
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

function utils.fskv_get_cert_key()
    local cert = fskv.get("cert")
    if not cert then
        log.error("fskv", "get", "cert", "not exist")
        return false
    end
    local key = fskv.get("key")
    if not cert then
        log.error("fskv", "get", "key", "not exist")
        return false
    end
    return true, cert, key
end

function utils.fskv_set_cert_key(cert, key)
    local ret
    if type(cert) ~= "string" then
        log.error("fskv", "set", "wrong cert type", type(cert))
        return false
    end
    if type(key) ~= "string" then
        log.error("fskv", "set", "wrong cert type", type(key))
        return false
    end
    ret = fskv.set("cert", cert)
    if not ret then
        log.error("fskv", "set", "failed to set cert")
        return false
    end
    ret = fskv.set("key", key)
    if not ret then
        log.error("fskv", "set", "failed to set key")
        return false
    end
    return true
end

function utils.fskv_set_credentials(credentials)
    if type(credentials) ~= "table" then
        log.error("fskv", "set", "wrong cert type", type(cert))
        return false
    end
    if type(key) ~= "string" then
        log.error("fskv", "set", "wrong cert type", type(key))
        return false
    end

    assert(type(credentials) == "table", "credentials should be a table")
    assert(credentials.get("username") ~= nil, "missing username on setting credentials")
    assert(credentials.get("password") ~= nil, "missing password on setting credentials")
    assert(credentials.get("cert") ~= nil, "missing cert on setting credentials")
    assert(credentials.get("key") ~= nil, "missing key on setting credentials")

    assert(fskv.set("credentials", credentials), "failed to set credentials")
    return true
end

function utils.fskv_get_credentials()
    local credentials = fskv.get("credentials")
    if credentials == nil then
        return false
    end
    return true, credentials
end

function utils.handle_error(wait_ms)
    log.info("handle_error", "reboot")
    if type(wait_ms) == "number" then
        sys.wait(wait_ms)
    end
    rtos.reboot()
end

return utils