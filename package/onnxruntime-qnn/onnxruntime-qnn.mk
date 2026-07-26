################################################################################
#
# onnxruntime-qnn
#
# ONNX Runtime C library + Qualcomm QNN execution provider, vendored from the
# upstream manylinux aarch64 wheels (see blobs/onnxruntime-qnn/README.md).
#
# The QNN EP is a shared provider: onnxruntime dlopen()s
# libonnxruntime_providers_qnn.so when a session appends the "QNN" execution
# provider by name, so a stock libonnxruntime.so works and no source build
# against the QAIRT SDK is needed.
#
################################################################################

# Bump this whenever blobs/onnxruntime-qnn/ changes. Buildroot keys its build
# dir and per-package stamps off the version, so editing files inside a `local`
# SITE without bumping leaves the stamp valid and the new blobs are silently
# never installed.
ONNXRUNTIME_QNN_VERSION = 1.28.0
ONNXRUNTIME_QNN_SITE = $(NERVES_DEFCONFIG_DIR)/blobs/onnxruntime-qnn
ONNXRUNTIME_QNN_SITE_METHOD = local
ONNXRUNTIME_QNN_LICENSE = MIT (onnxruntime), PROPRIETARY (QNN provider)
ONNXRUNTIME_QNN_REDISTRIBUTE = NO
ONNXRUNTIME_QNN_INSTALL_STAGING = YES

# The Rust NIF links against libonnxruntime at build time when not using
# ort's load-dynamic; staging makes the .so available to the cross toolchain.
define ONNXRUNTIME_QNN_INSTALL_STAGING_CMDS
	if [ -d $(@D)/usr ] && find $(@D)/usr -type f 2>/dev/null | grep -q .; then \
		cp -a $(@D)/usr $(STAGING_DIR)/ ; \
	fi
endef

define ONNXRUNTIME_QNN_INSTALL_TARGET_CMDS
	if [ -d $(@D)/usr ] && find $(@D)/usr -type f 2>/dev/null | grep -q .; then \
		cp -a $(@D)/usr $(TARGET_DIR)/ ; \
	else \
		printf '\n*** onnxruntime-qnn: no blobs in blobs/onnxruntime-qnn/usr; nothing installed.\n\n' ; \
	fi
endef

$(eval $(generic-package))
