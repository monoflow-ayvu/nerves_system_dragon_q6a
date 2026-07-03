################################################################################
#
# qcom-dsp-shell
#
# Hexagon DSP-side shell binaries + skels for the Radxa Dragon Q6A, taken
# from linux-msm/hexagon-dsp-binaries and installed into /usr/lib/dsp.
#
################################################################################

# Pinned commit on the "trunk" branch (frozen tuple, see GOAL.md).
QCOM_DSP_SHELL_VERSION = 2ba83638b373c0a6bbb7ecb32f5e2b9dfca2c4ce
QCOM_DSP_SHELL_SITE = $(call github,linux-msm,hexagon-dsp-binaries,$(QCOM_DSP_SHELL_VERSION))
QCOM_DSP_SHELL_LICENSE = PROPRIETARY (Qualcomm redistributable blobs)
QCOM_DSP_SHELL_REDISTRIBUTE = NO
QCOM_DSP_SHELL_INSTALL_STAGING = NO

# The shells and skels are Hexagon DSP6 ELFs (they run on the CDSP, not the
# CPU). Exempt /usr/lib/dsp from Buildroot's target-architecture check,
# which otherwise aborts with "architecture ... is QUALCOMM DSP6 Processor".
QCOM_DSP_SHELL_BIN_ARCH_EXCLUDE = /usr/lib/dsp

# Board-specific version directories inside the repo.
QCOM_DSP_SHELL_CDSP_DIR = qcs6490/radxa/dragon-q6a/CDSP.HT.2.5.c4-00004-KODIAK-1
QCOM_DSP_SHELL_ADSP_DIR = qcs6490/radxa/dragon-q6a/ADSP.HT.5.5.c9-00028-KODIAK-2

# Everything lives flat under /usr/lib/dsp. The CDSP set (fastrpc_shell_3,
# fastrpc_shell_unsigned_3, compute skels) is what fastrpc_test -a v68 uses;
# the ADSP set (fastrpc_shell_0, audio skels) rides along for later.
define QCOM_DSP_SHELL_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/dsp
	cp -a $(@D)/$(QCOM_DSP_SHELL_CDSP_DIR)/. $(TARGET_DIR)/usr/lib/dsp/
	cp -a $(@D)/$(QCOM_DSP_SHELL_ADSP_DIR)/. $(TARGET_DIR)/usr/lib/dsp/
endef

$(eval $(generic-package))
