# NemoPi-DTU
NemoPi data transfer unit firmware of AIR780X CAT-1 Modem

## Development environment 

Hardware: Hezhou AIR780XX CAT-1 Modem based on EC618 silicon 

Host operating system: Win10, Win11 

Firmware flashing tool: [Luatools_v2](https://luatos.com/luatools/download/last)

> Note: AIR780 uses a Microsoft defined COM PORT driver which availables in Windows 10. 
This driver only seems to work on native Window 10 machine. 
All COM PORTS can be recognised in Virtual Machine (VirtualBox), but the firmware flashing tool (Luatools_v2) cannot establish connection with the hardware in bootloader mode.  

## Development resource

- LuatOS API manual: https://wiki.luatos.org/api/index.html
- LuatOS source code and examples: https://gitee.com/openLuat/LuatOS
- Firmware over the air update (Chinese): https://doc.openluat.com/wiki/40?wiki_page_id=4632

## API 

### SMS API

Due to the cost of outbound SMS and challenges in handling international mobile number, most of the SMS commands will not respond over SMS. 

PING command is designed to return OK over SMS for functionality checking. Please use this API with care. 

| COMMAND | ARGUMENT | RETURN | NOTE |
|---|---|---|---|
| PING | N/A | OK | |
| REBOOT | N/A | N/A | |
| CREDENTIALS | URL | N/A | URL has to start with http:// or https:// |