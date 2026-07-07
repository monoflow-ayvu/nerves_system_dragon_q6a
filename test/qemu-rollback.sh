#!/usr/bin/env bash
#
# QEMU A/B rollback test for nerves_system_dragon_q6a.
#
# Builds on qemu-smoke.sh (same disk assembly + QEMU harness) and proves
# the update/rollback machinery WITHOUT the board:
#
#   Phase 1  fwup `upgrade` writes slot B + grubenv (validated=0,
#            booted_once=0). Boot: GRUB must give B its one try
#            ("Booting slot B"), and on-target autovalidate (erlinit
#            pre-run hook -> fwup -t autovalidate) must rewrite grubenv
#            on the ESP with validated=1.
#
#   Phase 2  Simulate a slot that used its one try without validating:
#            craft grubenv (boot=1, validated=0, booted_once=1). Boot:
#            GRUB must fall back ("falling back"), boot slot A, and the
#            on-target reconcile task must flip nerves_fw_active back
#            to "a" in the uboot-env area.
#
# Usage:
#   test/qemu-rollback.sh [path/to/example.fw]
#
# With no argument it (re)builds example/ for dragon_q6a first (same as
# qemu-smoke.sh). Requires qemu-system-aarch64, EDK2, fwup, mtools; the
# script re-execs inside nix-shell when they're missing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$REPO_DIR/test/work"
DISK_IMG="$WORK_DIR/rollback-disk.img"
SERIAL_LOG="$WORK_DIR/rollback-serial.log"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
DISK_SIZE="${DISK_SIZE:-6144}"
ESP_OFFSET=$((2048 * 512))         # BOOT_PART_OFFSET in fwup.conf
UBOOT_ENV_OFFSET=$((64 * 512))     # UBOOT_ENV_OFFSET in fwup.conf

if ! command -v qemu-system-aarch64 >/dev/null 2>&1 \
   || ! command -v fwup >/dev/null 2>&1 \
   || ! command -v mcopy >/dev/null 2>&1; then
    echo "[*] Re-executing inside nix-shell (qemu, fwup, mtools)..."
    exec nix-shell -p qemu fwup mtools --run "BOOT_TIMEOUT=$BOOT_TIMEOUT DISK_SIZE=$DISK_SIZE bash '$0' ${1:+"$1"}"
fi

mkdir -p "$WORK_DIR"

QEMU_PID=""
TAIL_PID=""
_cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    QEMU_PID=""; TAIL_PID=""
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

find_edk2() {
    local c
    for c in \
        "${EDK2_CODE:-}" \
        /run/current-system/sw/share/qemu/edk2-aarch64-code.fd \
        "$(dirname "$(command -v qemu-system-aarch64)")/../share/qemu/edk2-aarch64-code.fd" \
        /usr/share/qemu/edk2-aarch64-code.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd \
        /usr/share/edk2/aarch64/QEMU_EFI.fd; do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
    done
    c="$(find /nix/store /usr/share -name 'edk2-aarch64-code.fd' 2>/dev/null | head -1 || true)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    return 1
}
EDK2_CODE_FD="$(find_edk2)" || { echo "!! Set EDK2_CODE=/path/to/edk2-aarch64-code.fd" >&2; exit 1; }

FW="${1:-}"
if [ -z "$FW" ]; then
    echo "[*] Building example/ for dragon_q6a (NERVES_CONSOLE=ttyAMA0)..."
    (
        cd "$REPO_DIR/example"
        export MIX_TARGET=dragon_q6a
        export NERVES_CONSOLE=ttyAMA0
        mix deps.get
        mix firmware
    )
    FW="$REPO_DIR/example/_build/dragon_q6a_dev/nerves/images/example.fw"
fi
[ -f "$FW" ] || { echo "!! firmware not found: $FW" >&2; exit 1; }
echo "[*] Firmware: $FW"

# --- helpers -------------------------------------------------------------------

# boot_qemu <stop-regex>: boot the disk, stream serial to $SERIAL_LOG, stop
# when the regex appears (or on BOOT_TIMEOUT). Fresh EDK2 vars per call are
# NOT used - UEFI boot entries don't matter here (removable-media path).
boot_qemu() {
    local stop_re="$1" waited=0
    : > "$SERIAL_LOG"
    tail -n +1 -f "$SERIAL_LOG" &
    TAIL_PID=$!
    qemu-system-aarch64 \
        -M virt -cpu max -smp 4 -m 2048 -no-reboot \
        -drive if=pflash,format=raw,file="$CODE",readonly=on \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive file="$DISK_IMG",format=raw,if=none,id=hd0 \
        -device virtio-blk-device,drive=hd0 \
        -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
        -display none -serial "file:$SERIAL_LOG" -monitor none \
        </dev/null &
    QEMU_PID=$!
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        if grep -qE "$stop_re" "$SERIAL_LOG" 2>/dev/null; then
            echo "[*] Stop condition matched after ~${waited}s."
            break
        fi
        if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
            echo "[*] BOOT_TIMEOUT (${BOOT_TIMEOUT}s) reached."
            break
        fi
        sleep 2; waited=$((waited + 2))
    done
    # Give the guest a moment to finish in-flight ESP writes (autovalidate
    # runs just before IEx), then stop.
    sleep 5
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
    kill "$TAIL_PID" 2>/dev/null || true
    TAIL_PID=""
    sleep 0.2
}

# grubenv_var <name>: value of a variable in /EFI/BOOT/grubenv on the ESP.
grubenv_var() {
    mcopy -n -o -i "${DISK_IMG}@@${ESP_OFFSET}" ::/EFI/BOOT/grubenv "$WORK_DIR/grubenv.probe" 2>/dev/null
    tr -d '\0' < "$WORK_DIR/grubenv.probe" | grep -a "^$1=" | head -1 | cut -d= -f2 | tr -d '\r#'
}

# uboot_var <name>: value from the raw uboot-env KV area.
uboot_var() {
    dd if="$DISK_IMG" bs=512 skip=64 count=16 status=none | strings | grep "^$1=" | head -1 | cut -d= -f2
}

# write_grubenv key=val...: craft a valid 1 KiB GRUB environment block and
# put it on the ESP (what grub-editenv would produce).
write_grubenv() {
    local body="# GRUB Environment Block
"
    local kv
    for kv in "$@"; do body="${body}${kv}
"; done
    local len=${#body}
    local pad=$((1024 - len))
    { printf '%s' "$body"; head -c "$pad" /dev/zero | tr '\0' '#'; } > "$WORK_DIR/grubenv.crafted"
    mcopy -o -i "${DISK_IMG}@@${ESP_OFFSET}" "$WORK_DIR/grubenv.crafted" ::/EFI/BOOT/grubenv
}

ok=0
check() { if eval "$2"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; ok=1; fi; }

# --- assemble disk + QEMU firmware ---------------------------------------------
echo "[*] Assembling $DISK_IMG (${DISK_SIZE} MiB)..."
rm -f "$DISK_IMG"
truncate -s "${DISK_SIZE}M" "$DISK_IMG"
fwup -a -d "$DISK_IMG" -i "$FW" -t complete
mcopy -o -i "${DISK_IMG}@@${ESP_OFFSET}" "$REPO_DIR/test/grub.cfg.qemu" ::/EFI/BOOT/grub.cfg

CODE="$WORK_DIR/edk2-code.fd"
rm -f "$CODE"; cp "$EDK2_CODE_FD" "$CODE"; chmod u+w "$CODE"; truncate -s 64M "$CODE"
VARS="$WORK_DIR/edk2-vars.fd"
rm -f "$VARS"; truncate -s 64M "$VARS"

# --- Phase 1: upgrade to slot B, boot, expect autovalidate ----------------------
echo
echo "[*] PHASE 1: fwup upgrade -> boot slot B -> on-target autovalidate"
fwup -a -d "$DISK_IMG" -i "$FW" -t upgrade
[ "$(grubenv_var validated)" = "0" ] || { echo "!! expected validated=0 after upgrade"; exit 1; }
boot_qemu "Interactive Elixir|iex\("

echo "==================== PHASE 1 VERDICT ===================="
check "GRUB booted slot B"              "grep -qE 'Booting slot B' '$SERIAL_LOG'"
check "IEx console reached"             "grep -qE 'Interactive Elixir|iex\(' '$SERIAL_LOG'"
check "grubenv validated=1 (autovalidate wrote the ESP)" "[ \"\$(grubenv_var validated)\" = '1' ]"
check "uboot-env nerves_fw_validated=1" "[ \"\$(uboot_var nerves_fw_validated)\" = '1' ]"
check "uboot-env nerves_fw_active=b"    "[ \"\$(uboot_var nerves_fw_active)\" = 'b' ]"

# --- Phase 2: simulate failed first boot -> GRUB fallback -----------------------
echo
echo "[*] PHASE 2: craft grubenv (boot=1 validated=0 booted_once=1) -> expect fallback to A"
write_grubenv "boot=1" "booted_once=1" "validated=0"
boot_qemu "Interactive Elixir|iex\("

echo "==================== PHASE 2 VERDICT ===================="
check "GRUB detected the failed slot"   "grep -qE 'falling back' '$SERIAL_LOG'"
check "GRUB booted slot A (fallback)"   "grep -qE 'Booting slot A' '$SERIAL_LOG'"
check "IEx console reached"             "grep -qE 'Interactive Elixir|iex\(' '$SERIAL_LOG'"
check "grubenv flipped to boot=0"       "[ \"\$(grubenv_var boot)\" = '0' ]"
check "grubenv re-validated"            "[ \"\$(grubenv_var validated)\" = '1' ]"
check "reconcile flipped nerves_fw_active back to a" "[ \"\$(uboot_var nerves_fw_active)\" = 'a' ]"

echo "============================================================"
if [ "$ok" -eq 0 ]; then
    echo "ROLLBACK TEST PASSED"
else
    echo "ROLLBACK TEST FAILED - inspect $SERIAL_LOG"
fi
exit "$ok"
