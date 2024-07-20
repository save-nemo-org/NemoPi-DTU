-- Required by LuaTools for firmware generation
PROJECT = "nemopi-gps-test"
VERSION = "0.0.1"

_G.sys = require("sys")
_G.sysplus = require("sysplus")

-- Disable power key debouncing
if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

rtc.timezone(0)
socket.setDNS(socket.LWIP_GP, 1, "8.8.8.8")

sys.taskInit(function()
    -- GPIO mapping see: https://cdn.openluat-luatcommunity.openluat.com/attachment/20240716142135701_Air780E&Air780EG&Air780EX&Air700E_GPIO_table_20240716.pdf

    local GPS_V_BCKP = 23 -- AGPIO3 - GPIO23
    local GPS_3V3 = 25    -- AGPIO5 - GPIO25
    local GPS_UART_ID = 2
    local GPS_BAUD_RATE = 115200

    -- Turn on power 
    log.info("main", "setup", "gpio", GPS_V_BCKP)
    gpio.setup(GPS_V_BCKP, 1, gpio.PULLUP)

    log.info("main", "setup", "gpio", GPS_3V3)
    gpio.setup(GPS_3V3, 1, gpio.PULLUP)

    -- Setup and listen to UART
    log.info("main", "setup", "uart", GPS_UART_ID, "baudrate", GPS_BAUD_RATE)

    uart.setup(GPS_UART_ID, GPS_BAUD_RATE)
    uart.on(GPS_UART_ID, "receive", function(id, len)
        local data = uart.read(id, len)
        log.info("uart", id, len, data)
    end)

    log.info("done")

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
