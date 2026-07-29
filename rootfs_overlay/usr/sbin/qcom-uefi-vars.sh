#!/bin/sh
# Enable the Radxa EDK2 "Hypervisor Override" setting from Linux.
#
# Why: without it, ANY venus encode job hard-resets the SoC (PSHOLD warm
# reset from the hypervisor/TZ; decode works regardless). Measured with
# the override active: H.264 1080p encodes at ~87 fps through the VPU.
#
# Semantics of the variable (verified on-device, see
# docs/BOARD_QUIRKS.md "UEFI variables"):
#   - Writing 1 is a ONE-SHOT TRIGGER. At the next boot the firmware
#     applies the override into its own config store and RESETS the
#     visible variable back to 0 — and may reboot itself once more to
#     apply. The var therefore reads 0 while the override is ACTIVE.
#   - So the var value can NEVER be used to tell whether the override is
#     on. Key on a marker file instead; write the trigger once per
#     (device x boot-firmware) lifetime.
#   - The marker carries the SPI firmware version so a boot-firmware
#     update (which can reset hypervisor config) re-arms the trigger.
#   - DO NOT reboot here. This script can run in the first boot of an
#     UNVALIDATED A/B slot (e.g. a v0.6.x device OTA-ing onto this
#     image, which has no marker yet). Rebooting then would spend GRUB's
#     boot-once budget and get the update reverted. The trigger does not
#     need an immediate reboot: the firmware consumes it at the START of
#     whatever boot comes next — by which time the app has validated the
#     slot (Nerves.Runtime.StartupGuard), so the apply-reboot is free.
#
# efivarfs mechanics: file = 4 attribute bytes + value; attributes
# 0x00000007 = NV|BS|RT must be included in the write; chattr -i first
# (kernel marks entries immutable); write attrs+value in ONE write().

set -e

VAR_DIR=/sys/firmware/efi/efivars
VAR=$VAR_DIR/HypervisorOverride-e9139283-6a58-402f-b397-4c4671c9e067
MARK="/root/.hypervisor-override-requested@$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"

grep -q efivarfs /proc/mounts || mount -t efivarfs efivarfs $VAR_DIR 2>/dev/null || exit 0
[ -f $VAR ] || exit 0
[ -e "$MARK" ] && exit 0

# Marker FIRST: if it cannot be written (app partition not ready), skip the
# trigger entirely — retrying next boot is safe, a trigger without a marker
# would re-fire (and reboot) on every boot.
: > "$MARK" 2>/dev/null || exit 0

# attrs(4) + uint32 value LE; enable-trigger = 07 00 00 00  01 00 00 00
chattr -i $VAR 2>/dev/null || true
printf '\007\000\000\000\001\000\000\000' > $VAR

echo "qcom-uefi-vars: HypervisorOverride trigger set ($MARK); applies from next boot" > /dev/kmsg

exit 0
