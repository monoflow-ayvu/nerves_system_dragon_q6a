# Changelog

## v0.3.0

Added the QAIRT runtime for using the TPU.

## v0.2.0

CI now boots the built system end-to-end in QEMU (UEFI → GRUB → kernel →
erlinit → IEx) as a `qemu-smoke` job, and `deploy-system` is gated on it, so a
tag only publishes if the system actually boots. No image or runtime changes
since v0.1.1 — this release validates and exercises the full build → boot-test
→ publish pipeline.

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
