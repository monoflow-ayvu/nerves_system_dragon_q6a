#!/bin/sh
# Bring up udev, fix Hexagon NPU device node permissions and start the
# FastRPC daemon before the Elixir application starts. Run from
# erlinit.config via --pre-run-exec.
#
# Nerves uses BR2_INIT_NONE (no init system), so nothing else starts udevd,
# coldplugs devices, or launches daemons — everything systemd/udev did on
# RadxaOS happens here explicitly.

set -e

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
for d in cdsprpcd adsprpcd; do
    if command -v "$d" >/dev/null 2>&1 && ! pidof "$d" >/dev/null 2>&1; then
        "$d" &
    fi
done

exit 0
