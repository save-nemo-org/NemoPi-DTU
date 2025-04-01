-- Required by LuaTools for firmware generation
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

-- Disable power key debouncing
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

rtc.timezone(0)
socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

local utils = require("utils")

local function write_fskv()

    log.info("write_fskv", "start")

    log.info("write_fskv", "init fskv")
    fskv.init()

    log.info("write_fskv", "clear fskv")
    fskv.clear()

    -- get IMEI
    local imei = mobile.imei()
    log.info("write_fskv", "imei", imei)

    -- find <imei>.crt and <imei>.key in /luadb
    local crt_path = "/luadb/" .. imei .. ".crt"
    local key_path = "/luadb/" .. imei .. ".key"
    local cfg_path = "/luadb/" .. imei .. ".json"
    if not io.exists(key_path) or not io.exists(crt_path) or not io.exists(cfg_path) then
        log.error("key or crt not found")
        return
    else
        log.info("write_fskv", "crt_path", crt_path)
        log.info("write_fskv", "key_path", key_path)
        log.info("write_fskv", "cfg_path", cfg_path)
    end

    -- create credentials
    local credentials = {
        username = imei,
        password = "",
        cert = io.readFile(crt_path),
        key = io.readFile(key_path),
        host = json.decode(io.readFile(cfg_path))["host"],
        port = json.decode(io.readFile(cfg_path))["port"],
    }
    log.info("write_fskv", "credentials", json.encode(credentials))

    -- set credentials
    log.info("write_fskv", "set credentials")
    utils.fskv_set_credentials(credentials)

    -- create config
    local config = {
        read_interval_ms = 30 * 60 * 1000, -- 30 minutes
    }
    log.info("write_fskv", "config", json.encode(config))

    -- set config
    log.info("write_fskv", "set config")
    utils.fskv_set_config(config)

    log.info("write_fskv", "done")
end

sys.taskInit(function()
    
    write_fskv()
    
    while 1 do
        -- Print mem usage, debug only
        sys.wait(60 * 1000)

        log.info("lua", rtos.meminfo("lua"))
        log.info("sys", rtos.meminfo("sys"))
    end
end)

-- End of User Code ---------------------------------------------
-- Start scheduler
sys.run()
-- Don't program after sys.run()
