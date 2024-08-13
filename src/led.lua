local led = {}

local NET_LED_GPIO = 27
local FLASH_INTERVAL_MS = 1000 * 10 -- Run flash pattern every 10s
local ON_PERIOD_MS = 100
local OFF_PERIOD_MS = 200

led.WAIT_FOR_NETWORK = 1
led.NETWORK_CONNECTED = 2
led.MQTT_CONNECTED = 3
led.RUNNING = 4
led.ERROR = 5

function led.setMode(mode)
    assert(type(mode) == "number" and mode >= 1 and mode <= 5, "invalid led mode" .. mode)
    sys.publish("LED_UPDATE", mode)
end

sys.taskInit(function()
    gpio.setup(NET_LED_GPIO, 0)

    --[[
    LED flashing modes are represented by the number of blinks in each flashing period 
    LED blinks N times with on and off period defined by ON_PERIOD_MS and OFF_PERIOD_MS,
    where N is defined by flashing mode index respectively
    For example, LED blinks 1 time in mode 1, blinks 2 times in mode 2, and so on

    LED MODEs:
    1: Wait for NETWORK CONNECTION
    2: Wait for MQTT connection
    3: IDLE
    4: Running
    5: Error state
    ]]
    local led_mode = 1
    while 1 do
        assert(type(led_mode) == "number" and led_mode >= 1 and led_mode <= 5, "invalid led mode" .. led_mode)

        for i = 1, led_mode, 1 do
            gpio.set(NET_LED_GPIO, 1)
            sys.wait(ON_PERIOD_MS)

            gpio.set(NET_LED_GPIO, 0)
            sys.wait(OFF_PERIOD_MS)
        end

        -- sleep between each flash pattern while wait for led mode update 
        local ret, mode = sys.waitUntil("LED_UPDATE", FLASH_INTERVAL_MS)
        if ret then
            led_mode = mode
        end
    end
end)

return led
