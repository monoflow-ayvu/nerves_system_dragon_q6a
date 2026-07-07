#!/usr/bin/env bash
#
# QEMU smoke test for nerves_system_dragon_q6a.
#
# Proves the full boot chain WITHOUT the board:
#   EDK2 UEFI  ->  GRUB (BOOTAA64.EFI on the ESP)  ->  slot A from grubenv
#   ->  kernel loaded out of the squashfs  ->  erlinit  ->  IEx console.
#
# The Dragon Q6A kernel is a mainline 6.18 arm64 kernel with virtio built
# in, so the same Image that boots the board also boots `-M virt`. We swap
# in a QEMU grub.cfg (ttyAMA0, no board DTB) and build the example firmware
# with NERVES_CONSOLE=ttyAMA0 so erlinit lands IEx on the PL011 UART.
#
# Usage:
#   test/qemu-smoke.sh [path/to/example.fw]
#
# With no argument it (re)builds example/ for the dragon_q6a target first.
# Requires: qemu-system-aarch64, EDK2 aarch64 firmware, fwup, mtools. All
# are provided by the repo's shell.nix + `nix-shell -p qemu`; the script
# re-execs itself inside nix-shell if the tools aren't already on PATH.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$REPO_DIR/test/work"
DISK_IMG="$WORK_DIR/disk.img"
SERIAL_LOG="$WORK_DIR/serial.log"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
DISK_SIZE="${DISK_SIZE:-6144}"   # MiB; must exceed the fwup partition layout

# --- Re-exec inside nix-shell if the tooling isn't available ------------------
if ! command -v qemu-system-aarch64 >/dev/null 2>&1 \
   || ! command -v fwup >/dev/null 2>&1 \
   || ! command -v mcopy >/dev/null 2>&1; then
    echo "[*] Re-executing inside nix-shell (qemu, fwup, mtools)..."
    exec nix-shell -p qemu fwup mtools --run "BOOT_TIMEOUT=$BOOT_TIMEOUT DISK_SIZE=$DISK_SIZE bash '$0' ${1:+"$1"}"
fi

mkdir -p "$WORK_DIR"

# --- Signal handling ----------------------------------------------------------
# The only step that used to swallow Ctrl-C was QEMU in -nographic mode: its
# stdio mux puts the tty in raw mode, so Ctrl-C became a guest keypress. We now
# boot QEMU with its serial redirected to a file (see below), so QEMU never
# touches the tty, it stays in cooked mode, and Ctrl-C is a normal SIGINT that
# terminates the foreground pipeline. This trap just tidies the background tail.
#
# (Do NOT run the build under job control / in a background process group: mix
# and its Docker build_runner call tcsetattr on the tty, which raises SIGTTOU
# and kills the job even on a normal, no-Ctrl-C run.)
TAIL_PID=""
QEMU_PID=""
_cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    QEMU_PID=""
    TAIL_PID=""
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

# --- Locate the EDK2 aarch64 firmware -----------------------------------------
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
    # Last resort: search the nix store / filesystem.
    c="$(find /nix/store /usr/share -name 'edk2-aarch64-code.fd' 2>/dev/null | head -1 || true)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    return 1
}

EDK2_CODE_FD="$(find_edk2)" || {
    echo "!! Could not find edk2-aarch64-code.fd. Set EDK2_CODE=/path/to/it." >&2
    exit 1
}
echo "[*] EDK2 firmware: $EDK2_CODE_FD"

# --- Build the example firmware (unless a .fw was passed) ---------------------
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

# --- Assemble a raw disk image ------------------------------------------------
echo "[*] Assembling $DISK_IMG (${DISK_SIZE} MiB)..."
rm -f "$DISK_IMG"
truncate -s "${DISK_SIZE}M" "$DISK_IMG"
fwup -a -d "$DISK_IMG" -i "$FW" -t complete

# --- Swap the ESP grub.cfg for the QEMU variant -------------------------------
# ESP starts at LBA 2048 (BOOT_PART_OFFSET in fwup.conf) => byte 1048576.
ESP_OFFSET=$((2048 * 512))
echo "[*] Overwriting /EFI/BOOT/grub.cfg on the ESP with the QEMU variant..."
mcopy -o -i "${DISK_IMG}@@${ESP_OFFSET}" "$REPO_DIR/test/grub.cfg.qemu" ::/EFI/BOOT/grub.cfg
echo "[*] ESP contents:"
mdir -i "${DISK_IMG}@@${ESP_OFFSET}" ::/EFI/BOOT/ || true

# --- Boot under QEMU ----------------------------------------------------------
# aarch64 `-M virt` defines two 64 MiB flash banks. Pad the EDK2 code image
# to 64 MiB in the work dir (the nix store copy may be a different size and
# is read-only), and make a matching 64 MiB vars store.
CODE="$WORK_DIR/edk2-code.fd"
rm -f "$CODE"
cp "$EDK2_CODE_FD" "$CODE"
chmod u+w "$CODE"        # nix-store source is read-only; truncate needs write
truncate -s 64M "$CODE"
VARS="$WORK_DIR/edk2-vars.fd"
truncate -s 64M "$VARS"   # fresh each run so grubenv/boot state is clean

echo "[*] Booting QEMU (timeout ${BOOT_TIMEOUT}s). Serial -> $SERIAL_LOG"
: > "$SERIAL_LOG"

# Stream the guest serial live without handing QEMU the controlling terminal, so
# the tty stays in cooked mode and Ctrl-C raises SIGINT to this script (rather
# than being captured by QEMU's -nographic stdio mux).
tail -n +1 -f "$SERIAL_LOG" &
TAIL_PID=$!

# -cpu cortex-a76: matches the real target (ARMv8.2, LSE atomics); QEMU's
# default cortex-a57/a72 is ARMv8.0 and would SIGILL in the BEAM. Do NOT use
# -cpu max: QEMU 8.2 (ubuntu-24.04) aborts on it with kernel 6.18
# ("regime_is_user: code should not be reached" once the kernel enables
# hardware dirty-bit management).
# Guest serial -> file (not -nographic stdio), no tty attached, so backgrounding
# QEMU is safe (no SIGTTOU) and Ctrl-C reaches this script as a normal SIGINT.
qemu-system-aarch64 \
    -M virt \
    -cpu "${QEMU_CPU:-cortex-a76}" \
    -smp 4 \
    -m 2048 \
    -no-reboot \
    -drive if=pflash,format=raw,file="$CODE",readonly=on \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK_IMG",format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -monitor none \
    </dev/null &
QEMU_PID=$!

# Stop as soon as the boot reaches the IEx console (the definitive "system
# booted the BEAM" signal), or at BOOT_TIMEOUT. QEMU never exits on its own once
# it hits IEx, so without this the run would always burn the full timeout - and
# emulated boot on a loaded CI runner (TCG, no KVM) is several times slower than
# on real hardware. On real hw / recent QEMU the app banner prints just before
# IEx and is captured too; under old QEMU (distorted TCG clock) nerves_runtime's
# p4 format can stall so the app never starts - that check is non-fatal below.
waited=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if grep -qE "Interactive Elixir|iex\(" "$SERIAL_LOG" 2>/dev/null; then
        echo "[*] Boot reached the IEx console after ~${waited}s; stopping QEMU."
        break
    fi
    if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
        echo "[*] BOOT_TIMEOUT (${BOOT_TIMEOUT}s) reached; stopping QEMU."
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""
kill "$TAIL_PID" 2>/dev/null || true
TAIL_PID=""
sleep 0.2   # let tail flush the final lines before the verdict grep

# --- Verdict ------------------------------------------------------------------
echo
echo "==================== SMOKE TEST VERDICT ===================="
ok=0
# Hard checks: the system boot chain (UEFI -> GRUB -> kernel -> erlinit -> IEx).
check() { if grep -qiE "$2" "$SERIAL_LOG"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; ok=1; fi; }
# Soft check: informational, never fails the run.
warn_check() { if grep -qiE "$2" "$SERIAL_LOG"; then echo "  [PASS] $1"; else echo "  [WARN] $1 (non-fatal)"; fi; }

check "GRUB selected slot A"        "Booting slot A"
check "Kernel booted (Linux banner)" "Linux version 6\.18"
check "Reached userspace/erlinit"    "Starting Erlang|erlinit|Loading Erlang"
check "IEx console"                  "Interactive Elixir|iex\("
# The example app only starts after nerves_runtime formats/mounts the data
# partition (p4). That can stall under an old QEMU's distorted TCG clock (works
# on real hardware and recent QEMU), so treat the banner as informational rather
# than gating releases on an emulator quirk.
warn_check "Example app banner"      "EXAMPLE APP UP"

echo "============================================================"
if [ "$ok" -eq 0 ]; then
    echo "SMOKE TEST PASSED"
else
    echo "SMOKE TEST FAILED - inspect $SERIAL_LOG"
fi
exit "$ok"
