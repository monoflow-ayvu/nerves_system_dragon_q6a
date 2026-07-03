################################################################################
#
# qcom-fastrpc
#
# Qualcomm FastRPC userspace (libcdsprpc/libadsprpc, cdsprpcd/adsprpcd,
# fastrpc_test), built from source with autotools.
#
################################################################################

# qualcomm/fastrpc, branch "development". Pinned by commit for the frozen
# tuple (see GOAL.md). Override with BR2_PACKAGE_QCOM_FASTRPC_VERSION-style
# edits here when bumping.
QCOM_FASTRPC_VERSION = 706071caca54b9a56d78793c30d04351de5fbd96
QCOM_FASTRPC_SITE = $(call github,qualcomm,fastrpc,$(QCOM_FASTRPC_VERSION))
QCOM_FASTRPC_LICENSE = BSD-3-Clause
QCOM_FASTRPC_LICENSE_FILES = LICENSE.txt

# autogen.sh runs `autoreconf`; let Buildroot drive that instead.
QCOM_FASTRPC_AUTORECONF = YES
QCOM_FASTRPC_DEPENDENCIES = host-pkgconf libyaml libbsd

QCOM_FASTRPC_INSTALL_STAGING = YES

# No systemd on Nerves; point the udev rules at the eudev dir and drop the
# systemd unit. sysusers isn't available either - the fastrpc group is
# created (if needed) via the rootfs skeleton/coldplug instead.
QCOM_FASTRPC_CONF_OPTS = \
	--with-udevrulesdir=/lib/udev/rules.d \
	--with-systemdsystemunitdir=no

# The package's own 60-fastrpc.rules ACLs the DSP nodes to a `fastrpc` group
# via setfacl - both are systemd/sysusers/acl concepts absent on Nerves, so
# udevd just logs errors. Drop them; rootfs_overlay/etc/udev/rules.d/
# 99-qcom-npu.rules already sets the nodes 0666 (the RadxaOS approach).
define QCOM_FASTRPC_REMOVE_SYSTEMD_BITS
	rm -f $(TARGET_DIR)/lib/udev/rules.d/60-fastrpc.rules
	rm -f $(TARGET_DIR)/usr/lib/sysusers.d/fastrpc.conf
endef
QCOM_FASTRPC_POST_INSTALL_TARGET_HOOKS += QCOM_FASTRPC_REMOVE_SYSTEMD_BITS

$(eval $(autotools-package))
