local utils = {}

local libfota = require("libfota")

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
    if not key:startsWith("-----BEGIN RSA PRIVATE KEY-----") then
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

function utils.fskv_set_config(config)
    if type(config) ~= "table" then
        return false
    end

    local temp = {}

    local read_interval_ms = config["read_interval_ms"]
    if type(read_interval_ms) ~= "number" then
        return false
    end
    temp["read_interval_ms"] = read_interval_ms

    assert(fskv.set("config", temp), "failed to set config")
    return true
end

function utils.fskv_get_config()
    local config = fskv.get("config")
    if config == nil then
        return false
    end
    return true, config
end

-- download credentials from url and save into fskv
-- no return value
function utils.download_credentials(url)
    if type(url) ~= "string" then
        log.error("download_credentials", "invalid url")
        return
    end
    if not url:startsWith("http://") and not url:startsWith("https://") then
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
        log.info("download_credentials", "success")
    end)
end

function utils.reboot_with_delay_blocking(wait_ms)
    -- default to 1s for debouncing
    if wait_ms == nil then
        wait_ms = 1000
    end
    log.info("reboot_with_delay_blocking", wait_ms)
    sys.wait(wait_ms)
    rtos.reboot()
end

function utils.reboot_with_delay_nonblocking(wait_ms)
    log.info("reboot_with_delay_nonblocking", wait_ms)
    sys.taskInit(function()
        utils.reboot_with_delay_blocking(wait_ms)
    end)
end

function utils.ota(url)
    if type(url) ~= "string" then
        log.error("ota", "invalid ota url")
        return
    end
    -- use .bin file generated from luatools
    if not url:startsWith("http://") and not url:startsWith("https://") then
        log.error("ota", "unsupported ota url")
        return
    end
    local function fota_cb(ret)
        if ret == 0 then
            log.info("ota", "ota complete, reboot!")
            rtos.reboot()
        else
            log.error("ota", "ota failed with error code", ret, "url", url)
        end
    end
    libfota.request(fota_cb, url)
end

function utils.cell_info()
    mobile.reqCellInfo(60)
    if not sys.waitUntil("CELL_INFO_UPDATE", 60 * 1000) then
        log.error("cellinfo", "timeout")
        return json.null
    end
    local info = mobile.getCellInfo()
    log.info("cell", json.encode(info))
    return info
end

return utils
