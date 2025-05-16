local utils = {}

local libfota = require("libfota")

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
