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

function utils.fskv_set_credentials(credentials)
    assert(type(credentials) == "table", "credentials should be a table")
    assert(credentials["username"] ~= nil, "missing username on setting credentials")
    assert(credentials["password"] ~= nil, "missing password on setting credentials")
    assert(credentials["cert"] ~= nil, "missing cert on setting credentials")
    assert(credentials["key"] ~= nil, "missing key on setting credentials")

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