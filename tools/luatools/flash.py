"""
End-to-end Luatools flash helper.

Wraps the working procedure for flashing a project to a connected board via the
Luatools_v3 Skill API. The procedure isn't complicated, but the API has enough
sharp edges (project.delete leaves the .ini on disk, flash/status lies after the
write completes, lib/default_lib settings get reset by some flows) that having
it codified saves time on every flash.

Steps:
  1. Force-delete the project's .ini file from disk (the API's project.delete
     drops the in-memory registration but Luatools rescans the dir on the next
     list and re-registers from the file).
  2. project.create  — firmware .soc + initial main.lua.
  3. project.update default_lib=true — relies on Luatools' built-in lib
     (libfota, libnet, lbsLoc, air153C_wtd, …). See CLAUDE.md → Reference docs
     for where the source lives if you need to read a module's API.
  4. add_file each <src>/*.lua. The Skill API has no "add directory" — loop it.
  5. project.syntax_check  — must return errors:[].
  6. project.flash mode={script|all}.
  7. Watch the tools_<date>.txt log for "Burn OK!" — this is the authoritative
     completion signal. flash/status's `active` flag can stay True long after.
  8. Watch the newest trace_*.txt for "I/user.main setup" — confirms the
     post-flash boot ran our code through to the main loop.

Usage (default targets G2111Y-E):

    .venv\\Scripts\\python.exe tools\\luatools\\flash.py

Or with overrides:

    .venv\\Scripts\\python.exe tools\\luatools\\flash.py \\
        --project-name nemopi-d780l1y \\
        --platform platforms/D780L1Y \\
        --firmware firmware_core/LuatOS-SoC_V1113_EC618.soc

Requires the Skill API at http://127.0.0.1:38380 (Luatools_v3 ≥ 3.2.8).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

REPO_ROOT = Path(__file__).resolve().parents[2]
API_BASE = "http://127.0.0.1:38380"

DEFAULT_LUATOOLS = Path("C:/Users/han/Code/luatools2")
DEFAULT_PROJECT = "nemopi-g2111ye"
DEFAULT_FIRMWARE = REPO_ROOT / "firmware_core" / "V2024_Air780EP" / "LuatOS-SoC_V2024_Air780EP_1.soc"
DEFAULT_PLATFORM = REPO_ROOT / "platforms" / "G2111YE"
DEFAULT_SRC = REPO_ROOT / "src"


def _post(action: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = json.dumps({"action": action, "params": params or {}}).encode()
    req = urllib.request.Request(
        f"{API_BASE}/skill/action",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        raise SystemExit(f"Skill API unreachable at {API_BASE} — is Luatools_v3 ≥ 3.2.8 running?\n  {e}")


def _must(result: dict[str, Any], label: str) -> dict[str, Any]:
    if not result.get("ok"):
        raise SystemExit(f"{label} failed: {result.get('error')}")
    return result.get("result", {})


def _winpath(p: Path) -> str:
    """Luatools accepts both, but / paths are clearer in logs."""
    return str(p).replace("\\", "/")


def _latest_trace(luatools: Path) -> Optional[Path]:
    traces = sorted(
        (luatools / "log").glob("trace_*.txt"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return traces[0] if traces else None


def _tools_log(luatools: Path) -> Path:
    return luatools / "log" / f"tools_{time.strftime('%Y%m%d')}.txt"


def _wait_for(
    check: Callable[[], Optional[Any]],
    timeout: float,
    label: str,
    poll: float = 2.0,
) -> Any:
    deadline = time.monotonic() + timeout
    last_print = 0.0
    while time.monotonic() < deadline:
        result = check()
        if result is not None:
            return result
        # Periodic "still waiting" tick so a hung step is obvious.
        elapsed = timeout - (deadline - time.monotonic())
        if elapsed - last_print > 15:
            print(f"  …still waiting for {label} ({int(elapsed)}s elapsed)")
            last_print = elapsed
        time.sleep(poll)
    raise SystemExit(f"timed out waiting for {label} after {timeout:.0f}s")


def step_delete_ini(luatools: Path, name: str) -> None:
    ini = luatools / "project" / f"{name}.ini"
    if ini.exists():
        ini.unlink()
        print(f"  removed {ini}")
    else:
        print(f"  {ini.name} not on disk — already clean")


def step_create(name: str, firmware: Path, main_lua: Path) -> None:
    _must(
        _post(
            "project.create",
            {
                "project_name": name,
                "core_path": _winpath(firmware),
                "script_path": _winpath(main_lua),
            },
        ),
        "project.create",
    )


def step_enable_default_lib(name: str) -> None:
    _must(
        _post(
            "project.update",
            {"project_name": name, "updates": {"default_lib": True}},
        ),
        "default_lib=true",
    )


def step_add_src_files(name: str, src_files: list[Path]) -> None:
    for f in src_files:
        _must(
            _post(
                "project.update",
                {"project_name": name, "updates": {"add_file": _winpath(f)}},
            ),
            f"add_file {f.name}",
        )
        print(f"  + {f.name}")


def step_syntax_check(name: str) -> None:
    result = _must(
        _post("project.syntax_check", {"project_name": name}),
        "project.syntax_check",
    )
    errors = result.get("errors") or []
    if errors:
        print("  syntax errors:")
        for e in errors:
            print(f"    {e.strip()}")
        raise SystemExit("syntax_check returned errors")
    print("  clean")


def step_flash(name: str, mode: str) -> None:
    _must(
        _post("project.flash", {"project_name": name, "mode": mode}),
        "project.flash",
    )


def step_wait_burn_ok(luatools: Path, mode: str) -> None:
    tools_log = _tools_log(luatools)
    start_size = tools_log.stat().st_size if tools_log.exists() else 0

    def check():
        if not tools_log.exists():
            return None
        with open(tools_log, "rb") as fh:
            fh.seek(start_size)
            data = fh.read().decode("utf-8", errors="replace")
        if "Burn FAIL" in data:
            raise SystemExit("Burn FAIL in tools log — flash failed")
        if "Burn OK!" in data:
            return True
        return None

    # `all`-mode flashes may need the user to hold Boot — give them longer.
    timeout = 600 if mode == "all" else 180
    _wait_for(check, timeout=timeout, label="'Burn OK!' in tools log")
    print(f"  Burn OK! (tools log: {tools_log.name})")


def step_wait_main_setup(luatools: Path, flash_started_at: float) -> Path:
    def check():
        latest = _latest_trace(luatools)
        if latest is None:
            return None
        # Only count a trace file modified after the flash kicked off — guards
        # against false-matching a stale "I/user.main setup" line in an older
        # rotated trace.
        if latest.stat().st_mtime < flash_started_at:
            return None
        with open(latest, encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        if "I/user.main setup" in content:
            return latest
        return None

    return _wait_for(check, timeout=120, label="'I/user.main setup' in fresh trace")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--project-name", default=DEFAULT_PROJECT)
    parser.add_argument("--firmware", type=Path, default=DEFAULT_FIRMWARE)
    parser.add_argument("--platform", type=Path, default=DEFAULT_PLATFORM,
                        help="directory containing the platform's main.lua")
    parser.add_argument("--src", type=Path, default=DEFAULT_SRC,
                        help="directory of additional .lua files (added one by one)")
    parser.add_argument("--luatools", type=Path, default=DEFAULT_LUATOOLS,
                        help="Luatools_v3 install dir (for project/ and log/ paths)")
    parser.add_argument("--mode", choices=["script", "all"], default="script",
                        help="'all' flashes firmware + script (needs Boot-button dance)")
    parser.add_argument("--skip-watch", action="store_true",
                        help="trigger the flash and exit; don't wait for boot")
    args = parser.parse_args()

    main_lua = args.platform / "main.lua"
    if not args.firmware.exists():
        raise SystemExit(f"firmware not found: {args.firmware}")
    if not main_lua.exists():
        raise SystemExit(f"platform main.lua not found: {main_lua}")
    if not args.src.is_dir():
        raise SystemExit(f"src directory not found: {args.src}")
    src_files = sorted(args.src.glob("*.lua"))
    if not src_files:
        raise SystemExit(f"no .lua files in {args.src}")

    print(f"project    : {args.project_name}")
    print(f"firmware   : {args.firmware}")
    print(f"platform   : {args.platform} ({main_lua.name})")
    print(f"src        : {args.src} ({len(src_files)} files)")
    print(f"luatools   : {args.luatools}")
    print(f"mode       : {args.mode}")
    print()

    print("[1/8] delete project ini")
    step_delete_ini(args.luatools, args.project_name)
    print("[2/8] project.create")
    step_create(args.project_name, args.firmware, main_lua)
    print("[3/8] enable default_lib")
    step_enable_default_lib(args.project_name)
    print(f"[4/8] add {len(src_files)} src files")
    step_add_src_files(args.project_name, src_files)
    print("[5/8] syntax_check")
    step_syntax_check(args.project_name)
    print(f"[6/8] project.flash mode={args.mode}")
    flash_started_at = time.time()
    step_flash(args.project_name, args.mode)

    if args.skip_watch:
        print("[7/8] --skip-watch: not waiting for completion")
        return 0

    print("[7/8] wait for Burn OK in tools log")
    step_wait_burn_ok(args.luatools, args.mode)
    print("[8/8] wait for main setup in fresh trace")
    trace = step_wait_main_setup(args.luatools, flash_started_at)
    print(f"  OK. Boot reached main setup. trace: {trace}")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
