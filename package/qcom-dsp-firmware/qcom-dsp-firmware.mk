################################################################################
#
# qcom-dsp-firmware
#
# Kernel-loaded Hexagon DSP firmware (cdsp.mbn / adsp.mbn), Adreno GPU
# firmware (zap/SQE/GMU), Venus video firmware and GENI SE firmware for
# the Dragon Q6A. Vendored from upstream linux-firmware, where they are
# marked "Licence: Redistributable" (see LICENSE.qcom / NOTICE.qcom in the
# blobs dir and blobs/qcom-dsp-firmware/README.md for provenance).
#
# The package tolerates an empty blobs tree so the build stays green for
# the QEMU smoke test (which has no real DSP). On real hardware the .mbn
# files must be present or remoteproc cannot bring the CDSP up.
#
################################################################################

QCOM_DSP_FIRMWARE_VERSION = 1.0.0
QCOM_DSP_FIRMWARE_SITE = $(NERVES_DEFCONFIG_DIR)/blobs/qcom-dsp-firmware
QCOM_DSP_FIRMWARE_SITE_METHOD = local
QCOM_DSP_FIRMWARE_LICENSE = Redistributable, no modification (Qualcomm firmware)
QCOM_DSP_FIRMWARE_LICENSE_FILES = LICENSE.qcom NOTICE.qcom
QCOM_DSP_FIRMWARE_INSTALL_STAGING = NO

# cdsp.mbn/adsp.mbn are Hexagon firmware images; keep them out of the
# target-architecture check for when the blobs are harvested in.
QCOM_DSP_FIRMWARE_BIN_ARCH_EXCLUDE = /lib/firmware

define QCOM_DSP_FIRMWARE_INSTALL_TARGET_CMDS
	if find $(@D)/lib/firmware -type f \( -name '*.mbn' -o -name '*.mdt' \) 2>/dev/null | grep -q .; then \
		cp -a $(@D)/lib $(TARGET_DIR)/ ; \
	else \
		printf '\n*** qcom-dsp-firmware: no .mbn blobs found in blobs/qcom-dsp-firmware/lib/firmware.\n*** The CDSP will NOT boot on real hardware until they are harvested (Phase 0).\n*** This is expected/OK for the QEMU smoke test.\n\n' ; \
	fi
endef

$(eval $(generic-package))
