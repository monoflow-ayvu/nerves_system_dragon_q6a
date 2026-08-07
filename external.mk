# Include custom packages
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))

# --- Mesa Turnip (freedreno Vulkan) plumbing ---
#
# Buildroot 2026.05's package/mesa3d has no freedreno Vulkan option (upstream
# added it after this release), so the Kconfig symbol lives in Config.in and
# the meson wiring is done here. This file is included AFTER buildroot's
# builtin package .mk files (nerves_system_br's external.mk pulls it in), so
# MESA3D_CONF_OPTS already holds the builtin -Dvulkan-drivers= (empty: no
# builtin Vulkan driver is selected). Selects BR2_PACKAGE_MESA3D_VULKAN_DRIVER
# in Config.in so the builtin mesa3d.mk adds host-python-glslang and the
# vulkan-drivers plumbing; here we swap the empty driver list for freedreno.
#
# The msm kernel-mode driver is the default for freedreno-kmds in mesa 26.1.2;
# pass it explicitly so a mesa bump cannot silently flip the default.
#
# Drop this block and the Config.in symbol once nerves_system_br pins a
# Buildroot that ships BR2_PACKAGE_MESA3D_VULKAN_DRIVER_FREEDRENO.
ifeq ($(BR2_PACKAGE_MESA3D_VULKAN_DRIVER_FREEDRENO),y)
MESA3D_CONF_OPTS := $(filter-out -Dvulkan-drivers=,$(MESA3D_CONF_OPTS))
MESA3D_CONF_OPTS += -Dvulkan-drivers=freedreno
MESA3D_CONF_OPTS += -Dfreedreno-kmds=msm
endif
