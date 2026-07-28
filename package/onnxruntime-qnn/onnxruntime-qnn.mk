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
ONNXRUNTIME_QNN_VERSION = 1.28.0-qnn2.4.0
ONNXRUNTIME_QNN_SITE = $(NERVES_DEFCONFIG_DIR)/blobs/onnxruntime-qnn
ONNXRUNTIME_QNN_SITE_METHOD = local
ONNXRUNTIME_QNN_LICENSE = MIT (onnxruntime), PROPRIETARY (QNN provider)
ONNXRUNTIME_QNN_REDISTRIBUTE = NO
ONNXRUNTIME_QNN_INSTALL_STAGING = YES

# libQnnHtpV68Skel.so is a Hexagon binary ("QUALCOMM DSP6 Processor"), not AArch64 -
# it is loaded onto the DSP over FastRPC and never runs on the ARM cores. Buildroot's
# check-bin-arch rejects the whole package without this. Same treatment as
# QAIRT_RUNTIME_BIN_ARCH_EXCLUDE for /usr/lib/dsp.
# NOTE: check-bin-arch turns every -i into a DIRECTORY prefix (it appends a
# trailing slash), so excluding the skel by filename never matches - exclude
# the whole onnxruntime-qnn lib dir. The big AArch64 libonnxruntime lives one
# level up in /usr/lib and stays checked.
ONNXRUNTIME_QNN_BIN_ARCH_EXCLUDE = /usr/lib/onnxruntime-qnn

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
