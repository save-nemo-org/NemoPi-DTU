# Trae skills — digest

These five `SKILL.md` files were authored by the OpenLuat / Hezhou team for **Trae**
(a different programming agent). They are vendored here as reference; **they do not
auto-load in Claude Code**. Re-read this digest before touching them; it's faster than
re-reading the originals (~25 KB total, all Chinese).

## What each skill does

| Skill | Role | Trigger |
|---|---|---|
| `luatos-query-route-skill` | Entry-point router for any LuatOS question. Asks for the chip model (via `AskUserQuestion`), classifies the request (code / docs / chip-selection), then dispatches to the right MCP server. | First touch on any LuatOS question. |
| `luatos-new-project-skill` | Generates a brand-new LuatOS project from scratch — directory, `main.lua` from template, decoupled feature modules. | "Create a new LuatOS project". |
| `luatos-update-project-skill` | Modifies an existing LuatOS project — reuses existing modules, adds new ones, keeps existing style. | "Add X feature to my project". |
| `luatos-project-common-skill` | Library of sub-procedures the two project skills call into: MCP health check, demo lookup, decoupling rules, file-name rules, API validation, `main.lua` template, `/luadb/` resource rules. | Not invoked standalone. |
| `luatos-pua-skill` | Behavioural prompt ("no excuses, no fallback, MCP is the only source of truth"). | `/pua`, `/pua:on`, `/pua:off`. |

## The MCP servers they assume

Trae has these wired up; **Claude Code does not** unless someone installs them:

- `mcp_luatos-docs` — `search_docs`, `resolve_module`, `server_stats`. Canonical API docs.
- `mcp_luatos-code` — `search_code`, `list_demos`, `list_libs`, `server_stats`. Canonical demo / example index.

If you want the same level of API verification in Claude Code, install those MCP
servers. Otherwise the primary lookup is <https://wiki.luatos.com/api/> (per-module
pages at `wiki.luatos.com/api/<module>.html` — reachable from `WebFetch`); secondary
sources are <https://docs.openluat.com/> (often WAF-blocked from automated fetchers)
and <https://gitee.com/openLuat/LuatOS/tree/master/module>.

## Conventions worth carrying into `src/`

These are the rules the Trae skills enforce on generated code. They are reasonable to
follow when writing or modifying our own Lua modules, regardless of which agent is
running:

- **Decoupled modules.** `main.lua` only `require`s; **never** put feature logic there.
  Every feature — even a trivial timer — lives in its own module. Inter-module
  communication goes through `sys.publish`/`sys.subscribe` or `sys.sendMsg`/`sys.waitMsg`.
- **File name length ≤ 23 bytes**, no directory path in `require` (`require "http_app"`,
  not `require "lib/http_app"`). Don't collide with Lua stdlib / LuatOS core / extension
  library names.
- **`return` only if needed.** Modules with no externally accessed symbols don't need a
  trailing `return {...}`.
- **No `require` for core libraries.** `log`, `mqtt`, `fskv`, `crypto`, `http`,
  `socket`, `pack`, `pm`, `json`, etc. are global — never `require` them.
- **Resource files live under `/luadb/`** (e.g. `/luadb/font.bin`, `/luadb/logo.jpg`).
  This applies to both flashed firmware and the PC simulator.
- **`main.lua` template (per the skill):**
  - `PROJECT` and `VERSION` globals
  - `log.info("main", PROJECT, VERSION)`
  - `errDump.config(true, 600)` — comment out by default
  - FOTA hook — comment out by default
  - Memory monitor timer — comment out by default
  - Watchdog block — *delete entirely* on Air700/780/8000-series (per the skill),
    *enable* on Air1601/1602/6201/8101-series
  - `require` lines
  - `sys.run()` — must be last
- **PUA rule that's worth borrowing:** when the canonical knowledge source is
  unavailable (docs / MCP / specific URL), **stop and ask** rather than guess or fall
  back to web search or training memory. Hallucinated API calls on a microcontroller
  brick devices.

## Where we diverge from the template

Worth being explicit, so future you doesn't "fix" working code:

- **`platforms/EC618/main.lua` keeps the watchdog enabled** (`wdt.init(9000)` +
  `sys.timerLoopStart(wdt.feed, 3000)`) even though our AIR780XX is in the
  Air700/780/8000 family that the template tells you to strip the wdt block from. The
  9 s timeout is load-bearing for our deployment — see the gotchas section of
  `CLAUDE.md`. Don't strip it.
- **`src/nemopi.lua` is invoked from `main.lua` via `require("nemopi")` and contains
  the boot `sys.taskInit`.** The Trae template forbids logic in `main.lua`; we keep
  the platform `main.lua` thin and put everything in `src/` — same spirit, slightly
  different layout because of our two-platform (`EC618`, `PC`) split.
