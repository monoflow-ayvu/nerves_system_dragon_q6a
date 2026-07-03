# Changelog

## v0.1.0

Initial bring-up: Qualcomm UEFI → GRUB (arm64-efi) → A/B squashfs slots,
kernel + `qcs6490-radxa-dragon-q6a.dtb` inside each slot, Hexagon NPU
userspace (cdsp firmware, DSP shell, fastrpc, optional QAIRT) vendored as
Buildroot packages. QEMU-validated boot chain; on-board NPU validation
pending bench time.
