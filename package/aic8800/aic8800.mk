################################################################################
#
# aic8800
#
# Aicsemi AIC8800D80 USB WiFi 6 + Bluetooth vendor driver and firmware
# (the Dragon Q6A's onboard Quectel FCU760K module), from Radxa's DKMS
# packaging. Pinned commit = release 5.0+git20260123.5f7be68d-6.
#
################################################################################

AIC8800_VERSION = bd11969265809a0fc948f1107c8256bbb2c1aa60
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
AIC8800_LICENSE = PROPRIETARY (Aicsemi vendor driver and firmware)
AIC8800_REDISTRIBUTE = NO

# Radxa's git tree is unpatched; their deb applies debian/patches/series
# (quilt) at build time. The series carries the kernel >= 6.x compat
# fixes (in_irq removal etc.), the /lib/firmware/aic8800_fw firmware
# path and the BlueZ-instead-of-Bluedroid default - all required here.
define AIC8800_APPLY_DEBIAN_PATCHES
	# Some driver sources are CRLF while the patches are LF; normalize
	# the text files first or several hunks fail on line endings.
	cd $(@D) && find src/USB/driver_fw/drivers -type f \
		\( -name '*.c' -o -name '*.h' -o -name 'Makefile' -o -name 'Kconfig' \) \
		-exec sed -i 's/\r$$//' {} +
	cd $(@D) && sed -e 's/#.*//' -e '/^[[:space:]]*$$/d' debian/patches/series | \
		while read -r p; do \
			echo "aic8800: applying debian/patches/$$p"; \
			patch -g0 -p1 -E --no-backup-if-mismatch -d . < debian/patches/$$p || exit 1; \
		done
endef
AIC8800_POST_PATCH_HOOKS += AIC8800_APPLY_DEBIAN_PATCHES

# Build the aic8800 tree (aic_load_fw + aic8800_fdrv, one Kbuild pass so
# fdrv sees aic_load_fw's Module.symvers) and aic_btusb, as DKMS does.
AIC8800_MODULE_SUBDIRS = \
	src/USB/driver_fw/drivers/aic8800 \
	src/USB/driver_fw/drivers/aic_btusb

# The firmware blobs are not target ELFs; skip the arch check.
AIC8800_BIN_ARCH_EXCLUDE = /lib/firmware

# Firmware for all USB chip variants; the driver reads
# /lib/firmware/aic8800_fw/USB/aic8800D80/* for the D80 via direct file
# I/O (no request_firmware), so the exact path matters.
define AIC8800_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800_fw/USB
	cp -a $(@D)/src/USB/driver_fw/fw/. $(TARGET_DIR)/lib/firmware/aic8800_fw/USB/
endef

$(eval $(kernel-module))
$(eval $(generic-package))
