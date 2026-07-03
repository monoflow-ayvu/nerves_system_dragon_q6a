#!/bin/sh
#
# Burn a Nerves .fw to an additional disk (e.g. the M.2 NVMe) with freshly
# generated partition GUIDs so it can coexist with an already-burned medium
# (e.g. the microSD) in the same machine. grub.cfg probes the PARTUUID of
# the disk it boots from, so unique GUIDs are all that's needed.
#
# Usage:
#   ./install-to-disk.sh <firmware.fw> <device>
#
# Examples:
#   # From the build host (M.2 in a USB adapter):
#   sudo ./install-to-disk.sh _build/dragon_q6a_dev/nerves/images/app.fw /dev/sdX
#
#   # From a Nerves device booted off the SD card (installs to the M.2):
#   ./install-to-disk.sh /data/app.fw /dev/nvme0n1
#
# Afterwards pick the boot medium in the UEFI setup (boot order).

set -e

FW="${1:?usage: install-to-disk.sh <firmware.fw> <device>}"
DEV="${2:?usage: install-to-disk.sh <firmware.fw> <device>}"

fwup -a -i "$FW" -d "$DEV" -t complete

# The .fw carries fixed partition GUIDs (resolved at fwup compile time), so
# randomize them post-burn to keep root=PARTUUID unambiguous across media.
# grub.cfg probes the boot disk's PARTUUID at boot, so any values work as
# long as they are unique per medium. sgdisk -G rewrites the disk GUID and
# every partition's unique GUID (and fixes both GPT copies' CRCs).
sgdisk -G "$DEV"

echo "Done. $DEV now carries its own partition GUIDs and can coexist with"
echo "other Nerves media in the same machine. Select the boot medium in the"
echo "UEFI setup."
