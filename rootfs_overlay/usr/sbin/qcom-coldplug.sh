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
#    - autovalidate: when nerves_fw_autovalidate=1, a freshly upgraded slot
#      that boots this far validates itself so GRUB keeps booting it.
#    Never let bookkeeping failures block the app from starting.
#    NOTE: probe fwup by absolute path. The nerves-common busybox has no
#    `command` builtin (ASH_CMDCMD off), so `command -v fwup` here fails
#    and silently skips the whole block (bug found via QEMU rollback test).
OPS_FW=/usr/share/fwup/ops.fw
if [ -e "$OPS_FW" ] && [ -e /dev/rootdisk0 ] && [ -x /usr/bin/fwup ]; then
    /usr/bin/fwup -q -t reconcile -d /dev/rootdisk0 "$OPS_FW" || true
    /usr/bin/fwup -q -t autovalidate -d /dev/rootdisk0 "$OPS_FW" || true
fi

# 1. Dynamic device management (eudev). Start the daemon and coldplug.
if [ -x /sbin/udevd ] || [ -x /usr/sbin/udevd ]; then
    mkdir -p /run/udev
    udevd --daemon 2>/dev/null || /sbin/udevd --daemon 2>/dev/null || true
    udevadm trigger --type=subsystems --action=add 2>/dev/null || true
    udevadm trigger --type=devices --action=add 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
fi

# 2. Belt-and-braces permissions for the DSP nodes in case the udev rules
#    didn't cover them (they normally do; see 99-qcom-npu.rules).
chmod 666 /dev/fastrpc-* 2>/dev/null || true
chmod 666 /dev/dma_heap/* 2>/dev/null || true

# 3. FastRPC daemons. cdsprpcd keeps the CDSP FastRPC session alive
#    (audio aDSP equivalent is adsprpcd; only start what's installed).
#    They write nothing to the rootfs; logs go to the kernel ring buffer.
#    The qualcomm/fastrpc build installs these under /usr/sbin, which isn't
#    always on PATH this early, so probe explicit locations.
for d in cdsprpcd adsprpcd; do
    for bin in "/usr/sbin/$d" "/usr/bin/$d"; do
        if [ -x "$bin" ] && ! pidof "$d" >/dev/null 2>&1; then
            "$bin" &
            break
        fi
    done
done

exit 0
