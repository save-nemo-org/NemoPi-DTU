# soc_script — vendored Luatools default lib

This directory is a snapshot of Luatools' built-in "default lib" — the
set of Lua-side helpers (`libfota`, `libnet`, `lbsLoc`, `air153C_wtd`,
the `ex*` extension modules, …) that Luatools normally bundles into a
project automatically when `default_lib = true`.

We vendor it here for two reasons:

1. **Reproducibility.** Luatools' built-in lib changes between tool
   releases. Pinning a known-good copy in the repo means a checkout +
   flash on a different machine (or the same machine months from now)
   produces the same script bundle.

2. **Visibility.** When something we use here misbehaves (`libfota`,
   `air153C_wtd`, etc.) the source is right next to ours, not buried
   under `%LOCALAPPDATA%/Luatools/...`.

## Layout

    soc_script/
      v<luatools-lib-version>/
        lib/
          *.lua          ← the bundled extension libraries

## How to wire it into a Luatools project

Set the project's `lib` field to the absolute path of `lib/`, and turn
**off** `default_lib` so Luatools doesn't *also* drop in its own (now
older) copy on top of ours:

```
project.update / project.create →
    lib          = <repo>/soc_script/v2026.05.20.10/lib
    default_lib  = false
```

Via the Skill API:

```bash
curl -sS -X POST http://127.0.0.1:38380/skill/action \
  -H 'Content-Type: application/json' \
  -d '{
    "action":"project.update",
    "params":{
      "project_name":"<name>",
      "updates":{
        "lib":"C:/Users/.../NemoPi-DTU/soc_script/v2026.05.20.10/lib",
        "default_lib": false
      }
    }
  }'
```

## How to refresh

When Luatools ships a new version of the default lib and we want to
adopt it:

1. In Luatools: **3. 合宙各种资源入口 → 3.3 离线资源下载 →** download the new
   default lib (lands under `resource/soc_script/v<new-version>/`).
2. Copy the whole `v<new-version>/` directory into this folder.
3. Update each project's `lib` path to point at the new version.
4. Keep the old version directory around until every fielded unit is
   confirmed off the old lib (or just keep history forever — the lib is
   small, ~1.4 MB unzipped).
