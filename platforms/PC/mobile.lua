local mobile = {}

-- Allow the developer to override the simulator's IMEI from the environment.
-- Useful for exercising the provisioning flow against the real Azure backend
-- (which only accepts IMEIs pre-loaded into the devices table).
--
--   $env:NEMOPI_TEST_IMEI = "123456789012345"  # PowerShell
--   export NEMOPI_TEST_IMEI=123456789012345    # bash
local function env_imei()
    if os and os.getenv then
        local v = os.getenv("NEMOPI_TEST_IMEI")
        if type(v) == "string" and #v > 0 then return v end
    end
    return nil
end

function mobile.apn()

end

function mobile.imei()
   return env_imei() or "000000"
end

function mobile.setAuto()

end

function mobile.reqCellInfo()
   sys.publish("CELL_INFO_UPDATE")
end

function mobile.getCellInfo()
   return {}
end

return mobile
