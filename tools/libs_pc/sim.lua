local sim = {}

local utils = require("utils")
local mobile = require("mobile")

function sim.setup()
    log.info("sim", "setup")
    _G.mobile = require("mobile")
    _G.sms = require("sms")

    -- setup database
    log.info("sim", "setup", "fskv")
    utils.fskv_setup()

    log.info("sim", "setup", "fskv", "credentials")
    local credentials = {
        username = mobile.imei(),
        password = "password",
        cert = io.readFile("/luadb/" .. mobile.imei() .. ".crt"),
        key = io.readFile("/luadb/" .. mobile.imei() .. ".key")
    }
    local ret = utils.fskv_set_credentials(credentials)
    assert(ret, "failed to set credentials")

    log.info("sim", "setup", "fskv", "config")
    local config = io.readFile("/luadb/config.json")
    local ret = utils.fskv_set_config(json.decode(config))
    assert(ret, "failed to set config")
end

return sim