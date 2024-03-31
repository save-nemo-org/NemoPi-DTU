local sms_service = {}

local system_service = require("system_service")

sys.taskInit(function()
    while 1 do
        local ret, num, txt, metas = sys.waitUntil("SMS_INC", 300000)
        log.info("sms", ret, num, txt, metas and json.encode(metas) or "")
        if num then
            local result = system_service.system_call(system_service.parse_cmd_args(txt))
            sms.send(num, result, false)
        end
    end
end)

return sms_service
