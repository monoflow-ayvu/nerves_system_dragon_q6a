# Changelog

## v0.1.1

Packaging fix so the system builds and publishes from a clean checkout.
`package_files` referenced a nonexistent `linux-dragon-q6a.config` (the
kernel config fragment is `linux-dragon-q6a.fragment`), omitted the
`busybox.fragment` referenced by `nerves_defconfig`, and listed the empty,
untracked `patches/` directory. No image or runtime changes.

## v0.1.0

Initial bring-up: Qualcomm UEFI → GRUB (arm64-efi) → A/B squashfs slots,
kernel + `qcs6490-radxa-dragon-q6a.dtb` inside each slot, Hexagon NPU
userspace (cdsp firmware, DSP shell, fastrpc, optional QAIRT) vendored as
Buildroot packages. QEMU-validated boot chain; on-board NPU validation
pending bench time.
