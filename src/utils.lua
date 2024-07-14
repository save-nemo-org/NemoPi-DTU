local utils = {}

function utils.starts_with(str, start)
    return str:sub(1, #start) == start
end

function utils.ends_with(str, ending)
    return ending == "" or str:sub(- #ending) == ending
end

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
    if type(credentials) ~= "table" then
        return false
    end

    local temp = {}

    local username = credentials["username"]
    if type(username) ~= "string" then
        return false
    end
    temp["username"] = username

    local password = credentials["password"]
    if type(password) ~= "string" then
        return false
    end
    temp["password"] = password

    local cert = credentials["cert"]
    if type(cert) ~= "string" then
        return false
    end
    temp["cert"] = cert

    local key = credentials["key"]
    if type(key) ~= "string" then
        return false
    end
    temp["key"] = key

    assert(fskv.set("credentials", temp), "failed to set credentials")
    return true
end

function utils.fskv_get_credentials()
    local credentials = fskv.get("credentials")
    if credentials == nil then
        return false
    end
    return true, credentials
end

-- download credentials from url and save into fskv
-- no return value
function utils.download_credentials(url)
    if type(url) ~= "string" then
        log.error("download_credentials", "invalid url")
        return
    end
    if not utils.starts_with(url, "http://") and not utils.starts_with(url, "https://") then
        log.error("download_credentials", "url has to start with http:// or https://")
        return
    end
    -- http client works in task
    sys.taskInit(function()
        sys.wait(1000)
        local code, _, body = http.request("GET", url).wait()
        if code ~= 200 then
            log.error("download_credentials", "download failed", "code", code)
            return
        end

        local creds = json.decode(body)
        local ret = utils.fskv_set_credentials(creds)
        if not ret then
            log.error("download_credentials", "failed to parse and save credentials")
        end
        log.error("download_credentials", "success")

        utils.reboot_with_delay(1000)
    end)
end

function utils.reboot_with_delay(wait_ms)
    -- default to 1s for debouncing
    if wait_ms == nil then
        wait_ms = 1000
    end
    log.info("reboot_with_delay", wait_ms)
    sys.timerStart(function()
        rtos.reboot()
    end, wait_ms)
end

return utils
