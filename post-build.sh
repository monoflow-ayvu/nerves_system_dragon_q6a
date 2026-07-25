#!/bin/sh

set -e

# Find grub-editenv: prefer the Buildroot host tool if present, fall back to
# the build host's PATH (needs grub-common/grub2-tools installed).
if [ -x "$HOST_DIR/usr/bin/grub-editenv" ]; then
    GRUB_EDITENV="$HOST_DIR/usr/bin/grub-editenv"
elif [ -x "$HOST_DIR/bin/grub-editenv" ]; then
    GRUB_EDITENV="$HOST_DIR/bin/grub-editenv"
else
    GRUB_EDITENV=grub-editenv
fi

# Create the Grub environment blocks that select the A/B boot slot.
# boot=0 -> slot A, boot=1 -> slot B (read by grub.cfg's load_env).
$GRUB_EDITENV $BINARIES_DIR/grubenv_a create
$GRUB_EDITENV $BINARIES_DIR/grubenv_a set boot=0
$GRUB_EDITENV $BINARIES_DIR/grubenv_a set validated=0
$GRUB_EDITENV $BINARIES_DIR/grubenv_a set booted_once=0

$GRUB_EDITENV $BINARIES_DIR/grubenv_b create
$GRUB_EDITENV $BINARIES_DIR/grubenv_b set boot=1
$GRUB_EDITENV $BINARIES_DIR/grubenv_b set validated=0
$GRUB_EDITENV $BINARIES_DIR/grubenv_b set booted_once=0

cp $BINARIES_DIR/grubenv_a $BINARIES_DIR/grubenv_a_valid
$GRUB_EDITENV $BINARIES_DIR/grubenv_a_valid set booted_once=1
$GRUB_EDITENV $BINARIES_DIR/grubenv_a_valid set validated=1

cp $BINARIES_DIR/grubenv_b $BINARIES_DIR/grubenv_b_valid
$GRUB_EDITENV $BINARIES_DIR/grubenv_b_valid set booted_once=1
$GRUB_EDITENV $BINARIES_DIR/grubenv_b_valid set validated=1

# Grab the EFI grub image that Buildroot's grub2 arm64-efi target built.
# Its embedded prefix is /EFI/BOOT, which is where fwup places grub.cfg
# and grubenv on the ESP.
cp $BINARIES_DIR/efi-part/EFI/BOOT/bootaa64.efi $BINARIES_DIR/bootaa64.efi

# Our A/B grub.cfg (fwup writes it to the ESP; the copy that Buildroot put
# in efi-part/ is its generic sample and is not used).
cp $NERVES_DEFCONFIG_DIR/grub.cfg $BINARIES_DIR

# Remove any grub config the kernel/bootloader packages left in the target.
# GRUB lives on the ESP; the kernel image must stay at /boot inside the
# squashfs.
rm -rf $TARGET_DIR/boot/grub

# The kernel Image is installed to /boot by BR2_LINUX_KERNEL_INSTALL_TARGET.
#
# The board DTB is NOT on the boot path: the SPI-NOR EDK2 firmware hands the
# kernel its own DTB through the EFI configuration table, and grub.cfg
# deliberately issues no `devicetree` command. Keep the DTB we build as a
# bench reference only, so it can be diffed against the firmware's:
#   dtc -I fs -O dts /sys/firmware/devicetree/base > /tmp/fw.dts
#   dtc -I dtb -O dts /usr/share/dtb/qcs6490-radxa-dragon-q6a.dtb > /tmp/ours.dts
if [ -e $BINARIES_DIR/qcs6490-radxa-dragon-q6a.dtb ]; then
    install -D -m 0644 $BINARIES_DIR/qcs6490-radxa-dragon-q6a.dtb \
        $TARGET_DIR/usr/share/dtb/qcs6490-radxa-dragon-q6a.dtb
fi

# Compile the runtime firmware operations (revert/validate/factory-reset)
mkdir -p $TARGET_DIR/usr/share/fwup
NERVES_SYSTEM=$BASE_DIR $HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
# Support older versions of Nerves.Runtime that look for revert.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir so that the fwup.conf that's
# distributed with the system can find them.
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
