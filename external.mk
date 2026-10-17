# Include custom packages
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))

# Turnip note: on nerves_system_br 1.35.x (Buildroot 2026.08)
# BR2_PACKAGE_MESA3D_VULKAN_DRIVER_FREEDRENO is native — mesa3d.mk wires
# -Dvulkan-drivers=freedreno itself. The late -Dvulkan-drivers /
# -Dfreedreno-kmds=msm override that shimmed this on Buildroot 2026.05 was
# removed with the 1.35.1 bump; mesa >= 26 defaults freedreno-kmds to msm.
