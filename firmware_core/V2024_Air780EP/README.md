# LuatOS-SoC V2024 for Air780EP (EC718)

Source: copied 2026-05-22 from a Luatools_v3 install, specifically the
`resource/LuatOS_Air780EP/V2024版本, 发布于2026.01.29/` subdirectory of that
install.

| File | Size | SHA-256 |
|---|---|---|
| `LuatOS-SoC_V2024_Air780EP_1.soc` | 4,202,761 B | `c764a814a8427251c1a1e9363a03347991898083df292f56e0b1138919aaaf5d` |

Used together with `platforms/G2111YE/` to target the YED G2111Y-E carrier
board (Y100EP / Air780EP modem, EC718 silicon). To flash, see the
"Run / build / flash" section in `CLAUDE.md`.

## Why a separate per-chip-family firmware

`.soc` files are family-specific: EC618 / EC718 / etc. each ship their own.
We keep one directory per pinned version per family so a checkout uniquely
identifies the binary that was tested with this `src/`. See
`CLAUDE.md` → "Simulator and firmware version pinning".
