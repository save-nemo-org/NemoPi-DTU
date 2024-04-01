# NemoPi-DTU
NemoPi data transfer unit firmware of AIR780X CAT-1 Modem

## Development environment 

Hardware: Hezhou AIR780XX CAT-1 Modem based on EC618 silicon 

Host operating system: Windows 10 Professional 

Firmware flashing tool: [Luatools_v2](https://luatos.com/luatools/download/last)

> Note: AIR780 uses a Microsoft defined COM PORT driver which availables in Windows 10. 
This driver only seems to work on native Window 10 machine. 
All COM PORTS can be recognised in Virtual Machine (VirtualBox), but the firmware flashing tool (Luatools_v2) cannot establish connection with the hardware in bootloader mode.  

## Development resource

- LuatOS API manual: https://wiki.luatos.org/api/index.html
- LuatOS source code and examples: https://gitee.com/openLuat/LuatOS
- Firmware over the air update (Chinese): https://doc.openluat.com/wiki/40?wiki_page_id=4632
