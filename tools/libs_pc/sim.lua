local sim = {}

local utils = require("utils")

function sim.setup()
    log.info("sim", "setup")
    _G.simulation = true
    _G.mobile = require("mobile")
    _G.sms = require("sms")

    -- setup database
    log.info("sim", "setup", "fskv")
    utils.fskv_setup()
    local credentials = {
        username = mobile.imei(),
        password = "password",
        cert = io.readFile("/luadb/123456789012345.pem"),
        key = io.readFile("/luadb/123456789012345.key")
    }
    local ret = utils.fskv_set_credentials(credentials)
    assert(ret, "failed to set credentials")
end

return sim