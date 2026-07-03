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
# systemd unit. sysusers isn't available either — the fastrpc group is
# created (if needed) via the rootfs skeleton/coldplug instead.
QCOM_FASTRPC_CONF_OPTS = \
	--with-udevrulesdir=/lib/udev/rules.d \
	--with-systemdsystemunitdir=no

$(eval $(autotools-package))
