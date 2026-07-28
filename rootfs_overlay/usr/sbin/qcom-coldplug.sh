#!/bin/sh
# Bring up udev, fix Hexagon NPU device node permissions and start the
# FastRPC daemon before the Elixir application starts. Run from
# erlinit.config via --pre-run-exec.
#
# Nerves uses BR2_INIT_NONE (no init system), so nothing else starts udevd,
# coldplugs devices, or launches daemons - everything systemd/udev did on
# RadxaOS happens here explicitly.

set -e

# 0. A/B slot bookkeeping (see grub.cfg + fwup-ops.conf):
#    - reconcile: if GRUB auto-fell-back to the other slot, sync
#      nerves_fw_active with the slot that actually mounted /.
#    - autovalidate: OFF by default (nerves_fw_autovalidate=0 in fwup.conf).
#      Validating here would only prove the kernel booted and erlinit ran,
#      which lets a crash-looping Elixir release mark itself good and
#      defeats the whole point of the GRUB boot-once budget. The
#      application validates instead, via Nerves.Runtime.StartupGuard.
#      The call below stays because it is a no-op when the variable is 0,
#      and it preserves the opt-in for headless images that set it to 1.
#    Never let bookkeeping failures block the app from starting.
#    NOTE: probe fwup by absolute path. The nerves-common busybox has no
#    `command` builtin (ASH_CMDCMD off), so `command -v fwup` here fails
#    and silently skips the whole block (bug found via QEMU rollback test).
OPS_FW=/usr/share/fwup/ops.fw
if [ -e "$OPS_FW" ] && [ -e /dev/rootdisk0 ] && [ -x /usr/bin/fwup ]; then
    /usr/bin/fwup -q -t reconcile -d /dev/rootdisk0 "$OPS_FW" || true
    /usr/bin/fwup -q -t autovalidate -d /dev/rootdisk0 "$OPS_FW" || true
fi

# 0.5 UEFI variables. HypervisorOverride must be Enabled or VPU encode
#     hard-resets the SoC (see docs/BOARD_QUIRKS.md "UEFI variables").
#     Idempotent; reboots once on the first boot that flips it.
/usr/sbin/qcom-uefi-vars.sh || true

# 1. Dynamic device management (eudev). Start the daemon and coldplug.
if [ -x /sbin/udevd ] || [ -x /usr/sbin/udevd ]; then
    mkdir -p /run/udev
    udevd --daemon 2>/dev/null || /sbin/udevd --daemon 2>/dev/null || true
    udevadm trigger --type=subsystems --action=add 2>/dev/null || true
    udevadm trigger --type=devices --action=add 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
fi

# 2. Remoteproc recovery net. ADSP/CDSP firmware lives on the rootfs, so a
#    BUILTIN qcom_q6v5_pas requests it during initcalls -- before
#    prepare_namespace() mounts root -- gets -2, and parks the remoteproc
#    "offline" forever. That is exactly why the NPU was dead: no /dev/fastrpc-*
#    and 0x72 from every FastRPC call. QCOM_Q6V5_PAS is =m now so udev loads it
#    after the rootfs exists and auto_boot succeeds, making this loop a no-op.
#    It stays as insurance in case the symbol goes back to =y or udev misses the
#    modalias. Idempotent: anything already "running" is left alone.
#    NOTE: writing "start" blocks until firmware boot completes, so only do it
#    for remoteprocs that are actually offline.
for d in /sys/class/remoteproc/*/; do
    [ -w "$d/state" ] || continue
    if [ "$(cat "$d/state" 2>/dev/null)" = "offline" ]; then
        echo start > "$d/state" 2>/dev/null || true
    fi
done

# 3. DSP permissions + FastRPC daemons, in the background.
#    Remoteproc firmware boot is ASYNCHRONOUS, so `udevadm settle` above does
#    not imply the DSP is up: /dev/fastrpc-cdsp can appear a moment later, and
#    cdsprpcd started before it exists simply exits. Wait for the node -- but
#    never on the critical path, because this script runs before the BEAM and a
#    board with no working DSP must still boot promptly.
#    Permissions normally come from udev (99-qcom-npu.rules, MODE="0666"); the
#    chmod is belt-and-braces for nodes that appeared before the rules loaded.
(
    i=0
    while [ ! -e /dev/fastrpc-cdsp ] && [ "$i" -lt 20 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -e /dev/fastrpc-cdsp ] || exit 0

    chmod 666 /dev/fastrpc-* 2>/dev/null || true
    chmod 666 /dev/dma_heap/* 2>/dev/null || true

    # cdsprpcd keeps the CDSP FastRPC session alive (adsprpcd is the audio aDSP
    # equivalent; only start what is installed). They write nothing to the
    # rootfs; logs go to the kernel ring buffer. The qualcomm/fastrpc build
    # installs these under /usr/sbin, which is not always on PATH this early,
    # so probe explicit locations.
    for d in cdsprpcd adsprpcd; do
        for bin in "/usr/sbin/$d" "/usr/bin/$d"; do
            if [ -x "$bin" ] && ! pidof "$d" >/dev/null 2>&1; then
                "$bin" &
                break
            fi
        done
    done
) &

exit 0
