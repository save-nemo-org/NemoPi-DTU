-- Required by LuaTools for firmware generation 
PROJECT = "nemopi-dtu"
VERSION = "0.0.1"

--[[
MQTT is an inbuilt lib, so user doesn't need to import it explicitly 
]]

-- Sys is a required lib 
_G.sys = require("sys")
-- MQTT application need this lib 
_G.sysplus = require("sysplus")

-- Air780E的AT固件默认会为开机键防抖, 导致部分用户刷机很麻烦
-- Disable power key debouncing 
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

-- if rtos.bsp() == "EC618" and pm and pm.WORK_MODE then
--     pm.power(pm.WORK_MODE, 1)
-- end

-- 自动低功耗, 轻休眠模式
-- Air780E支持uart唤醒和网络数据下发唤醒, 但需要断开USB,或者pm.power(pm.USB, false) 但这样也看不到日志了
-- Enable auto sleep
-- pm.request(pm.LIGHT)

rtc.timezone(0)
socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")
socket.sntp({"0.pool.ntp.org", "1.pool.ntp.org", "time.windows.com"})

local system_service = require("system_service")
local sms_service = require("sms_service")
local mqtt_service = require("mqtt_service")

-- Setup NET LED --
local netLed = require("netLed")
local NETLED_PIN = 27
netLed.setup(true, NETLED_PIN, nil)

-- -- 以下是演示与uart结合, 简单的mqtt-uart透传实现,不需要就注释掉
-- local uart_id = 1
-- uart.setup(uart_id, 9600)
-- uart.on(uart_id, "receive", function(id, len)
--     local data = ""
--     while 1 do
--         local tmp = uart.read(uart_id)
--         if not tmp or #tmp == 0 then
--             break
--         end
--         data = data .. tmp
--     end
--     log.info("uart", "uart收到数据长度", #data)
--     sys.publish("mqtt_pub", pub_topic, data)
-- end)
-- sys.subscribe("mqtt_payload", function(topic, payload)
--     log.info("uart", "uart发送数据长度", #payload)
--     uart.write(1, payload)
-- end)

-- End of User Code ---------------------------------------------
-- Start scheduler 
sys.run()
-- Don't program after sys.run()
