# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

LuatOS-based firmware for a NemoPi Data Transfer Unit (DTU) built on the Hezhou AIR780XX CAT-1 modem (EC618 silicon). The DTU reads RS485/Modbus sensors and ships telemetry over MQTT (TLS) to an Azure Event Grid endpoint, and accepts cloud→device commands (ping, ota, reboot) plus a minimal SMS API (PING, REBOOT, OTA, CREDENTIALS).

## Run / build / flash

There is no test suite, linter, or compile step — Lua is loaded directly by LuatOS at boot.

- **Flash to device (EC618):** use [Luatools_v3](https://luatos.com/luatools/download/last) (GUI, Windows-only). Point it at the `.soc` in `firmware_core/` plus `platforms/EC618/` and `src/`. Luatools picks up `PROJECT`/`VERSION` from `platforms/EC618/main.lua`. The Microsoft USB-CDC driver used by AIR780 in bootloader mode only works reliably on native Windows 10/11 — flashing from a VM fails.
- **PC simulator:** `.\tools\bin\luatos-pc.exe .\platforms\PC\ .\src\` — runs the same `src/` code but with stub `mobile`, `sms`, `libfota` modules from `platforms/PC/`. Useful for exercising message-handling logic without hardware; networking/MQTT/Modbus will not behave realistically. **Simulate first** — see "Simulation-first workflow" below.
- **OTA test server:** `python tools/ota_server/server.py` serves the current directory on port 8000 so the device can pull a `.bin` (Luatools-generated) via the `ota` command or `OTA <url>` SMS.

### Luatools Skill API

Luatools_v3 exposes a Skill API that lets Claude drive the GUI programmatically (download firmware, build, flash). Upstream docs: <https://docs.openluat.com/protocols/ai/luatools/SKILL_API/>. It's a local HTTP server at `http://127.0.0.1:38380` — capabilities live at `/skill/capabilities`, actions are dispatched via `POST /skill/action`, and runtime events stream over `ws://127.0.0.1:38380/skill/events`. Available actions include `flash.firmware`, `project.flash`, `project.create/update/delete/list/details`, `project.combine/export/import`, `serial.*`, `trace.*`, `log.tail`, `device.reboot`. Treat the API as experimental — endpoints may shift, so when a call fails fall back to asking the developer for their Luatools install path and pull binaries straight from disk.

A local mirror lives at `agent/luatools_skill_api.md` (with a `Last checked:` stamp) plus the verbatim HTML at `agent/luatools_skill_api.html`. Refresh if the stamp is older than today — the host's SafeLine WAF 403s `WebFetch` and `curl`, but **PowerShell `Invoke-WebRequest` (aliased to `wget` on Windows) gets through**. See the `## How to refresh` block in the mirror for the exact command.

### Reference docs

| Purpose | URL | Reachable from Claude? | Local mirror |
|---|---|---|---|
| LuatOS Lua API reference (per-module pages: `mqtt`, `socket`, `fskv`, `crypto`, `mobile`, `pm`, `uart`, etc.) | <https://wiki.luatos.com/api/> | **Yes** — `WebFetch` works; individual pages live at `wiki.luatos.com/api/<module>.html` | none needed |
| Luatools Skill API (programmatic control of Luatools_v3) | <https://docs.openluat.com/protocols/ai/luatools/SKILL_API/> | **`Invoke-WebRequest` yes, `WebFetch`/`curl` 403** | `agent/luatools_skill_api.md` + `.html` |
| LuatOS-PC simulator user guide | <https://docs.openluat.com/common/LuatOS-pc/> | **`Invoke-WebRequest` yes, `WebFetch`/`curl` 403** | `agent/luatos_pc_simulator_guide.md` + `.html` |
| Chip selection guide (referenced by the Trae `query-route` skill) | <https://docs.openluat.com/SelectionGuide/SelectionGuide/> | Same as above (use `Invoke-WebRequest`) | not mirrored — selection happens once per product |

**Primary lookup for any LuatOS API question is `wiki.luatos.com/api/<module>.html`.** It's reachable, fast, and authoritative — use it before guessing module signatures or falling back to memory.

**For `docs.openluat.com` pages**, `WebFetch` and `curl` get 403'd by the upstream SafeLine WAF, but PowerShell's `Invoke-WebRequest` (Windows alias `wget`) passes — the WAF fingerprints the client, not the IP. The mirror files document the exact PowerShell command in their `## How to refresh` block.

### Simulator and firmware version pinning

**Always copy the simulator exe and the firmware `.soc` into this repo before development**, so a checkout uniquely identifies the binary that was used. The repo already pins:

- `firmware_core/LuatOS-SoC_V1113_EC618.soc` — the EC618 LuatOS core flashed alongside `src/`.
- `tools/bin/luatos-pc.exe` (+ `luat_uart_i686.dll`) — the PC simulator binary.

Source for both: Luatools_v3 → resource download (or the Skill API). When you pull a new version, commit it.

Hezhou chips support two OTA modes — **script-only** and **firmware + script**. A script built against a different `.soc` than the device is running can produce subtle, hard-to-debug failures. Keep every historical `.soc` we have ever shipped in `firmware_core/<version>/` with a short README noting the date range it was deployed and which fielded units are still on it, so we can service old devices on their original script until they are confidently migrated forward.

### Simulation-first workflow

Hezhou Lua modems share most of their API surface; chip-specific differences belong behind the `platforms/<bsp>/` layer. **Keep `src/` chip-agnostic.** Anything that depends on a particular chip's module goes in the platform `main.lua` or behind a stubbable global. Validate logic in the PC simulator before flashing — the simulator stubs `mobile`, `sms`, and `libfota`, but message routing, JSON shapes, command dispatch, and pure-Lua control flow all run identically.

### Vendor-supplied agent skills (`agent/trae/skills/`)

OpenLuat ships five `SKILL.md` files for **Trae** (a different programming agent). They are vendored read-only at `agent/trae/skills/` and **do not auto-load in Claude Code**. A digest with everything worth knowing — what each skill does, the MCP servers they assume (`mcp_luatos-docs`, `mcp_luatos-code`), conventions worth carrying into `src/`, and where this repo intentionally diverges from the template — lives at `agent/trae/skills/README.md`. Read that before opening the individual skills.

Two rules from those skills are worth honouring in Claude Code work:

- **Decoupled modules.** `platforms/<bsp>/main.lua` stays thin; feature logic belongs in modules under `src/`, and module-to-module communication goes through `sys.publish/subscribe` (already the pattern here — don't regress it).
- **Don't guess LuatOS APIs.** Look the module up on <https://wiki.luatos.com/api/> first (it's reachable and authoritative). If that's down, fall back to the Trae MCP servers (if installed) or the cached skill API. If none of those work, stop and ask the developer — do not fall back to web search or training memory. Hallucinated module/function calls on a microcontroller can brick fielded devices.

## Architecture

Two-layer layout: `platforms/<bsp>/main.lua` is the entry point selected at flash time; it sets BSP-specific globals/watchdog/APN, then `require("nemopi")` hands control to the platform-agnostic application in `src/`.

### Boot sequence (`src/nemopi.lua`)

1. `sms_setup()` registers the SMS command handler (PING/REBOOT/OTA).
2. `fskv_setup()` initialises the key-value flash store used for credentials and config.
3. `communication.init(imei, sub_topics)` — sets up network (DNS, NTP), fetches MQTT credentials, opens the TLS MQTT connection. **Blocking with hard timeouts** (5 min IP, 3 min NTP, 1 min MQTT); on failure the device sleeps 30 min then reboots.
4. Publishes a `connect` telemetry message, loads `read_interval_ms` from fskv (defaults to 30 min), subscribes to `MQTT_RECV` for command processing.
5. Sensor detection: iterates `sensors.sensor_classes`, calls `:detect()` on each, publishes a `detect` message describing what responded.
6. Main loop: enable power rails → read vbat/GPS/cell info/Lua+sys mem → publish `diagnosis` → call `:run()` on each detected sensor → publish `data` → disable power → `sys.wait(read_interval_ms)`.

### Module responsibilities

- **`src/communication.lua`** — single-instance MQTT wrapper. Credentials are fetched from `https://issuer.nemopi.com/api/certificate` (POST with `{"imei": ...}`) and cached in fskv under `"credentials"`. MQTT broker host is hardcoded (`nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net:8883`); the HTTPS response only supplies the client cert/key. Inbound MQTT is republished on the `MQTT_RECV` topic for the rest of the system.
- **`src/modbus.lua`** — Modbus-RTU master over a single UART (1 by default), with hardware RS485 EN on GPIO 25. Supports function codes 0x03/0x04. `read_register` sleeps `sys.wait(1000)` for the slave to respond — there is no smarter framing, so sensor reads are inherently 1 s+ apart.
- **`src/sensors.lua`** — sensor registry. Each entry under `sensors.sensor_classes` is a class with `:detect() → bool, instance`, `:info()`, `:run() → data[]`. `sensors.infrastructure.Gps` is separate from the detection loop because GPS is read inline from the diagnosis block. Currently shipping: `Ds18b20Logger` (Modbus slave 0x02). Sensor payload schemas are defined by the JSON tables built here and consumed by the cloud — keep field names (`channel`, `value`, `fault`) stable.
- **`src/power.lua`** — two switchable rails: `internal` (VPCB, GPIO 22) powers the RS485 transceiver and ADC; `external` (VOUT, GPIO 24) powers the attached sensors. The main loop toggles both off between read cycles to save power.
- **`src/led.lua`** — independent task driven by `LED_UPDATE` sys-events. Mode N = N blinks per 10 s cycle (`WAIT_FOR_NETWORK=1`, `NETWORK_CONNECTED=2`, `MQTT_CONNECTED=3`, `RUNNING=4`, `ERROR=5`).
- **`src/utils.lua`** — fskv config get/set, blocking/non-blocking reboot helpers, `ota(url)` via `libfota` (must be `http(s)://` and a `.bin` produced by Luatools), `cell_info()` waits up to 60 s for `CELL_INFO_UPDATE`.
- **`src/system_service.lua`** — older string-based command dispatcher (PING/ECHO/REBOOT/FIRMWARE/MODEM/CELL/SOCKET/OTA/MEM/HELP). **Not currently wired into nemopi.lua** — kept for reuse but the active command path is MQTT JSON via `process_command`.

### MQTT contract

Topic conventions and JSON schemas are authoritative in `README.md` — when changing payload shapes update both the producing code in `src/` and the README tables. Subscribe pattern is `buoys/<IMEI>/c2d/#`; publish topics are `buoys/<IMEI>/d2c/telemetry` and `buoys/<IMEI>/d2c/response`. The `msg_type` field discriminates `connect`/`detect`/`data`/`diagnosis`/`response`.

## Conventions and gotchas

- **LuatOS concurrency**: cooperative — every long operation is a `sys.taskInit(...)` and yields via `sys.wait(ms)` or `sys.waitUntil("EVENT", timeout)`. `sys.publish/subscribe` is the cross-task event bus.
- **Globals**: `log`, `rtos`, `mqtt`, `pwm`, `mobile`, `fskv`, `crypto`, `sms`, `json`, `socket`, `pack`, `pm`, `http` are LuatOS C-side globals (declared in `.vscode/settings.json` for the Lua language server). `sys`/`sysplus` are exported by each platform's `main.lua`. The PC simulator stubs `mobile`, `sms`, and `libfota` only — anything that touches `mqtt`, `fskv`, `crypto`, `http` won't run there.
- **Watchdog**: 9 s timeout, fed every 3 s by a timer in `platforms/EC618/main.lua`. Any blocking call longer than ~6 s without yielding will reset the device.
- **Forced 24 h reboot**: `platforms/EC618/main.lua` starts a `rtos.reboot` timer at boot. Long-lived state must survive a daily restart.
- **APN is hardcoded** to `hologram` (`mobile.apn(0, 1, "hologram", "", "", nil, 0)`).
- **Sensitive data**: MQTT certs land in fskv only (never in source). The `certs/` and `ota/` directories are gitignored — don't commit binaries or credentials into them.

## Python tooling

Helper scripts in `tools/` are Python 3 and **always run from a repo-local venv at `.venv/`** (gitignored). Don't install into the system Python and don't create venvs elsewhere — pinning the venv path keeps invocations identical across machines and across Claude sessions.

```powershell
# one-time setup
python -m venv .venv
.venv\Scripts\python.exe -m pip install <packages>

# invocation (no `activate` needed — call the venv python by path)
.venv\Scripts\python.exe tools\mkdocs_to_markdown.py <args>
```

Current Python helpers:

- `tools/ota_server/server.py` — stdlib only; serves the current directory on :8000 for OTA testing.
- `tools/geolocation/location.py` — needs `requests`; stub for cell-tower geolocation via Google.
- `tools/mkdocs_to_markdown.py` — needs `markdownify`, `beautifulsoup4`; extracts a readable markdown view from a saved mkdocs-material HTML page. Used to refresh `agent/luatools_skill_api.md` and `agent/luatos_pc_simulator_guide.md` after re-downloading their `.html` siblings.

When you add a new Python helper that needs third-party libs, install them into `.venv` and add a one-line note here so future sessions know what to `pip install`.
