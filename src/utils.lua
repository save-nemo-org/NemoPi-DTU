local utils = {}

function utils.fskv_setup()
    fskv.init()
    local used, total, kv_count = fskv.status()
    log.info("fskv", "used", used, "total", total, "kv_count", kv_count)

    -- print all data
    -- local iter = fskv.iter()
    -- if iter then
    --     while 1 do
    --         local k = fskv.next(iter)
    --         if not k then
    --             break
    --         end
    --         log.debug("fskv", "key", k, "value", fskv.get(k))
    --     end
    -- end
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

function utils.handle_error()
    log.info("handle_error", "reboot")
    rtos.reboot()
end

return utils