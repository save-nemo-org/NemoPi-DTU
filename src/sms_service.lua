local sms_service = {}

local system_service = require("system_service")

sys.taskInit(function()
    while 1 do
        local ret, num, txt, metas = sys.waitUntil("SMS_INC", 300000)
        log.info("sms", ret, num, txt, metas and json.encode(metas) or "")
        if num then
            local cb = function(msg)
                sms.send(num, msg, false)
            end
            system_service.system_call(txt, cb)
        end
    end
end)

return sms_service
