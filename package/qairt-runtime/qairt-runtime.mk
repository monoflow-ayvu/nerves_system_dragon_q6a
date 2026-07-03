################################################################################
#
# qairt-runtime
#
# Qualcomm AI Engine Direct (QAIRT/QNN) runtime blobs, vendored locally
# from the SDK (requires a Qualcomm account; local use only). Host libs go
# to /usr/lib, HTP V68 skels to /usr/lib/dsp so the DSP can load them.
#
################################################################################

QAIRT_RUNTIME_VERSION = 1.0.0
QAIRT_RUNTIME_SITE = $(NERVES_DEFCONFIG_DIR)/blobs/qairt-runtime
QAIRT_RUNTIME_SITE_METHOD = local
QAIRT_RUNTIME_LICENSE = PROPRIETARY
QAIRT_RUNTIME_REDISTRIBUTE = NO
QAIRT_RUNTIME_INSTALL_STAGING = NO

# HTP V68 skels under /usr/lib/dsp are Hexagon ELFs — skip the arch check.
QAIRT_RUNTIME_BIN_ARCH_EXCLUDE = /usr/lib/dsp

define QAIRT_RUNTIME_INSTALL_TARGET_CMDS
	if [ -d $(@D)/usr ] && find $(@D)/usr -type f 2>/dev/null | grep -q .; then \
		cp -a $(@D)/usr $(TARGET_DIR)/ ; \
	else \
		printf '\n*** qairt-runtime: no blobs in blobs/qairt-runtime/usr; nothing installed.\n\n' ; \
	fi
endef

$(eval $(generic-package))
