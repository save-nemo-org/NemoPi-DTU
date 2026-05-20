# LuatOS-PC simulator V2031 (32-bit)

Source: copied 2026-05-20 from a Luatools_v3 install, specifically the
`resource/LuatOS_PC/LuatOS-SoC_V2031_PC/` subdirectory of that install. To refresh,
ask the developer for their Luatools install path (Luatools_v3 is a portable install
so the path varies per machine) and re-copy from the same relative location.

| File | Size | SHA-256 |
|---|---|---|
| `luatos-pc.exe` | 27,247,616 B | `3e4e706fc07f32367cc475ac1e7b58b3de00b38723a519bcc4722fdaf40ef8d7` |
| `luat_uart_i686.dll` | 2,317,824 B | `24e80798e1fc33d50b76bad505d3e0cc5a47c4d8c1d6a4e1d46008450f1107c1` |

Upstream's folder also includes a 64-bit variant (`luatos-pc-64bit.exe`); not pulled in
yet — add it here if it's needed.

Launch from the repo root:

```powershell
.\tools\luatos_pc\V2031\luatos-pc.exe .\platforms\PC\ .\src\
```
