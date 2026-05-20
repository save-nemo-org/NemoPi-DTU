---
name: simulate
description: Run this project's PC simulator (LuatOS-PC) against the current src/ tree. Use when the user asks to run, launch, simulate, or test the firmware in simulation — e.g. "run the sim", "simulate", "try it in sim", "test src/ in the simulator". Also invoked by the built-in /run skill since the device firmware is not directly runnable.
---

# Simulate (PC simulator launcher)

This skill is the canonical way to run the NemoPi-DTU firmware in the LuatOS-PC simulator. It enforces the version-pinning rule (see `CLAUDE.md` → "Simulator and firmware version pinning") and drives the run: version check → launch → continuous log monitoring → diagnosis → clean shutdown.

**Important:** the firmware in `src/` changes often. Do **not** hardcode expected log strings or remembered failure patterns from previous runs in this skill or in your reasoning. **Every run, derive expectations from the current source code** in `src/` and `platforms/PC/`. The log file is the ground truth for this run; the Lua source is the ground truth for what should happen.

## Steps

### 1. Determine target version

The repo pins the simulator under `tools/luatos_pc/V<version>/`. Identify the newest directory there — that's the **currently pinned** version.

Ask the user (only if not already known this session) for the path to their Luatools install folder — Luatools_v3 is a portable install, so this varies per developer. Inside, the simulator lives at `resource/LuatOS_PC/LuatOS-SoC_V<version>_PC/`.

Compare:
- Pinned version (latest dir under `tools/luatos_pc/`)
- Luatools version (newest `LuatOS-SoC_V*_PC` dir in `resource/LuatOS_PC/`)

### 2. Upgrade if Luatools is newer

If Luatools has a newer version:
- Create `tools/luatos_pc/V<new>/`
- Copy `luatos-pc.exe` + `luat_uart_i686.dll` into it
- Write a `README.md` recording source path, SHA-256 of each file, and the copy date
- Update CLAUDE.md / README.md launch-command lines to point at the new version dir (use the existing references as templates)
- Do **not** delete the older version dir — historical copies stay for old-script servicing

If versions match, proceed without changes.

### 3. Derive expectations from current source

Before launching, **read the source** to build a fresh model of what this run should do. Cover at minimum:

- `platforms/PC/main.lua` — the entry point. What does it require, what does it set up before handing off to `nemopi`?
- `platforms/PC/mobile.lua`, `platforms/PC/sms.lua`, `platforms/PC/libfota.lua` — the simulator stubs. Note what each stubbed function returns (e.g. what does `mobile.imei()` return today?), because that often determines whether the script's onboarding will succeed.
- `src/nemopi.lua` — the boot `sys.taskInit`. Trace it top-to-bottom and list, in order, every `log.info/log.error`, every `sys.publish/waitUntil`, every `assert`, every `communication.publish` call, every `sys.wait` of significant duration. That's the spine of expected behaviour for this run.
- Any module `require`'d during boot — `communication`, `utils`, `modbus`, `power`, `sensors`, `led`. Check `init`/`setup`/`detect` entry points the boot path actually calls.

Note explicitly:
- Which **assertions** would terminate the simulator if they fail.
- Which **external services** the boot path contacts (HTTPS endpoints, MQTT brokers, NTP servers) — these are live network calls in the simulator.
- Which **terminal states** the code can reach: `rtos.reboot()`, `utils.reboot_with_delay_blocking(N)`, infinite `while 1` main loops. Identify them from the current source — values like the sleep duration are read out of the code, not remembered.

Do not assume past observations are still valid. If the code has changed since the last run, the expected timeline changes with it.

### 4. Launch in background

From the repo root:

```bash
./tools/luatos_pc/V<version>/luatos-pc.exe ./platforms/PC/ ./src/
```

The simulator writes its log to `pclogs/luatos_pc_<timestamp>.log` in the cwd. It does **not** stream to stdout — stdout will be empty. Capture the new log path immediately by listing `pclogs/` and taking the newest file.

### 5. Monitor the full log continuously

This is the core of the run. Repeat the loop:

1. Read **the entire log file** (not just new lines — the whole file each iteration). The logs are small (kilobytes), so cost is negligible and re-reading gives full context.
2. Compare current log contents against the expected timeline derived in step 3.
3. Decide: continue, stop, or escalate.

Loop cadence: poll every 3–5 seconds. Stop polling when a terminal state is reached or after a hard cap (~5 minutes wall clock; the boot path's longest internal timeout is 5 min for `IP_READY`, so anything past that is hung).

Things to watch for as you re-read each time:

- **Progress along the expected timeline** — are the `log.info` lines from the boot path appearing in the order the code dictates?
- **Errors (`E/...`)** — every error line is significant. Find the matching `log.error(...)` call in the source to identify which control-flow branch produced it.
- **Unexpected events** — log lines that don't correspond to anything in the source. Could indicate a LuatOS-side issue, a stub returning something unexpected, or an external service responding in a new way.
- **Stalls** — long gaps with no new log activity. Cross-reference against `sys.wait`/`sys.waitUntil` in the code: is the script intentionally sleeping (and for how long), or genuinely hung?
- **Terminal patterns derived from current code** — e.g. if the source's failure branch ends in `reboot_with_delay_blocking(N)`, watch for the corresponding log line and then kill the process before the N-ms sleep elapses.

When reporting findings, **cite the log line verbatim and point at the source line that produces it** (e.g. `src/communication.lua:75`). Do not paraphrase log lines — copy them exactly.

### 6. Stop on terminal state

Terminal states are read out of the current source, not remembered. Common ones in this codebase (verify they still exist in the source before relying on them):

- Lua-side `assert(...)` failure → simulator process usually exits on its own.
- A `rtos.reboot()` call in the boot path → about to actually reboot the simulator process.
- A `reboot_with_delay_blocking(N)` / `reboot_with_delay_nonblocking(N)` call → script is about to sleep N ms then reboot; kill before the sleep elapses.
- Successful entry into the main `while 1` loop → onboarding succeeded; let one or two iterations complete (so you observe `data`/`diagnosis` publishes), then stop.
- Process disappears from the process list → already exited; nothing more to do but read the final log.

To stop:

```powershell
Stop-Process -Name luatos-pc -Force -ErrorAction SilentlyContinue
```

### 7. Report and clean up

After stopping:
- Summarise: did the run reach the expected milestones derived in step 3? Cite log line numbers and source file:line for any divergence.
- If the run failed: name the specific source path that produced the failure and the upstream cause as evidenced by the log (e.g. an HTTP response code, a `sys.waitUntil` timeout, an assertion). Suggest a concrete next step — never a generic "try again".
- The simulator leaves `pclogs/luatos_pc_<timestamp>.log` and `fskv.bin` in the cwd. Both are gitignored. `fskv.bin` persists across runs (it simulates flash); if a test needs a clean KV state, delete it before launching.

## Notes

- The simulator's PC bsp uses **real OS networking** for `socket`, `http`, `mqtt`, `crypto`. Only cellular APIs (`mobile.*`), `sms`, and `libfota` are stubbed. So MQTT/HTTPS calls actually hit the network — be aware when running offline, on a restricted network, or when credentials would do real things against production endpoints.
- The Lua entry point in simulator mode is `platforms/PC/main.lua`, which loads stub `mobile`/`sms` then `require("nemopi")`. There is no watchdog in PC mode.
- 64-bit simulator (`luatos-pc-64bit.exe`) exists upstream but isn't pinned here yet. Pull it in if 32-bit ever misbehaves.
