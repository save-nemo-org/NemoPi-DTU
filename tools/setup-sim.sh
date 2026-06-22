#!/usr/bin/env bash
# tools/setup-sim.sh
#
# One-shot setup of the LuatOS-PC simulator for macOS and Linux.
# Clones the upstream repos at pinned commits, applies the fskv.bin
# persistence patch, and builds the simulator binary.
#
# Pinned commits match what the fskv patch was developed and tested against.
# Bump them (and re-test the patch) when pulling a new simulator version.
# The risk of NOT pinning: upstream changes luat_fskv_pc.c and the patch
# no longer applies cleanly → fskv.bin is never written → extract_creds.py fails.
#
# Run from the NemoPi-DTU repo root (or from anywhere — the script
# resolves its own location):
#
#   bash tools/setup-sim.sh
#
# Optional: override where the simulator repos are cloned:
#
#   SIM_PARENT=/my/dir bash tools/setup-sim.sh
#
# After a successful run the binary is at:
#   $SIM_PARENT/luatos-soc-pc/build/out/luatos-lua
#
# The simulator is then invoked like:
#   NEMOPI_TEST_IMEI=<imei> \
#     /path/to/luatos-lua ./platforms/PC/ ./src/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$REPO_ROOT/tools/patches/luat_fskv_pc_persist.patch"
# Pinned commits — bump both when pulling a new simulator version and
# re-verify the patch applies cleanly against the new tree.
LUATOS_COMMIT="13f2a57"         # openLuat/LuatOS
SIM_COMMIT="5914a27"            # openLuat/luatos-soc-pc
# By default clone as siblings of NemoPi-DTU
: "${SIM_PARENT:=$(dirname "$REPO_ROOT")}"

LUATOS_DIR="$SIM_PARENT/LuatOS"
SIM_DIR="$SIM_PARENT/luatos-soc-pc"

OS="$(uname -s)"

# ─── colour helpers ────────────────────────────────────────────────────────────
info()  { echo "  $*"; }
step()  { echo; echo "▸ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*" >&2; exit 1; }

echo
echo "NemoPi-DTU simulator setup"
echo "Repos will be cloned to: $SIM_PARENT"
echo "Platform: $OS"

# ─── 1. Prerequisites ──────────────────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v git &>/dev/null; then
    fail "git is required but not found"
fi
ok "git"

# xmake — try to install if missing
if ! command -v xmake &>/dev/null; then
    step "xmake not found — installing"
    if [[ "$OS" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install xmake
        else
            bash <(curl -fsSL https://xmake.io/shget.text)
            # shellcheck disable=SC1090
            source ~/.xmake/profile 2>/dev/null || true
        fi
    elif [[ "$OS" == "Linux" ]]; then
        bash <(curl -fsSL https://xmake.io/shget.text)
        # shellcheck disable=SC1090
        source ~/.xmake/profile 2>/dev/null || true
    else
        fail "Unsupported OS: $OS. Install xmake manually: https://xmake.io"
    fi
fi
ok "xmake $(xmake --version 2>/dev/null | head -1 | awk '{print $2}' || true)"

# Linux: 32-bit toolchain for the i386 build
if [[ "$OS" == "Linux" ]]; then
    if ! dpkg -l gcc-multilib &>/dev/null 2>&1; then
        step "Installing 32-bit toolchain (gcc-multilib)"
        sudo apt-get update -qq
        sudo apt-get install -y gcc-multilib g++-multilib
    fi
    ok "32-bit toolchain"
fi

# ─── 2. Clone repos ────────────────────────────────────────────────────────────
step "Cloning LuatOS (pinned $LUATOS_COMMIT)"
if [[ -d "$LUATOS_DIR/.git" ]]; then
    info "Already cloned at $LUATOS_DIR — skipping"
else
    git clone https://github.com/openLuat/LuatOS.git "$LUATOS_DIR"
    git -C "$LUATOS_DIR" checkout "$LUATOS_COMMIT"
fi
ok "LuatOS"

step "Cloning luatos-soc-pc (pinned $SIM_COMMIT)"
if [[ -d "$SIM_DIR/.git" ]]; then
    info "Already cloned at $SIM_DIR — skipping"
else
    git clone https://github.com/openLuat/luatos-soc-pc.git "$SIM_DIR"
    git -C "$SIM_DIR" checkout "$SIM_COMMIT"
fi
ok "luatos-soc-pc"

# ─── 3. Apply fskv persistence patch ──────────────────────────────────────────
step "Applying fskv.bin persistence patch"
cd "$SIM_DIR"
if git apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
    ok "Patch already applied — skipping"
elif git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    ok "Patch applied"
else
    echo "  ✗ Patch failed to apply cleanly against $SIM_COMMIT." >&2
    echo "    This usually means the commit pins in setup-sim.sh are out of date." >&2
    echo "    To fix: bump SIM_COMMIT/LUATOS_COMMIT to the new upstream HEAD," >&2
    echo "    run 'git diff port/luat_fskv_pc.c' after manually applying the change," >&2
    echo "    update tools/patches/luat_fskv_pc_persist.patch, and commit both." >&2
    exit 1
fi

# ─── 4. Build ─────────────────────────────────────────────────────────────────
step "Building simulator"
cd "$SIM_DIR"
export VM_64bit=1
export LUAT_USE_GUI=n

if [[ "$OS" == "Darwin" ]]; then
    xmake -y
elif [[ "$OS" == "Linux" ]]; then
    xmake f -p linux -a i386 -y
    xmake -y
fi

BIN="$SIM_DIR/build/out/luatos-lua"
if [[ ! -f "$BIN" ]]; then
    fail "Build succeeded but binary not found at $BIN"
fi
ok "Binary: $BIN"

# ─── 5. Done ──────────────────────────────────────────────────────────────────
echo
echo "Setup complete!"
echo
echo "Run the simulator:"
echo
echo "  NEMOPI_TEST_IMEI=<imei> \\"
echo "    $BIN \\"
echo "    $REPO_ROOT/platforms/PC/ \\"
echo "    $REPO_ROOT/src/"
echo
echo "Logs appear in $REPO_ROOT/pclogs/ and fskv.bin is written to the cwd."
echo "After provisioning run:  .venv/bin/python3 tools/streamdeck/extract_creds.py"
