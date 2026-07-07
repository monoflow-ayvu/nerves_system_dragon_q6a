# Changelog

## v0.4.0

Full hardware enablement + real A/B rollback:

- **A/B auto-rollback**: `grub.cfg` now implements boot-once semantics
  (`validated`/`booted_once` in grubenv, `save_env` on the ESP). New
  `fwup-ops.conf` tasks: slot-aware `validate`, boot-time `reconcile`
  (syncs `nerves_fw_active` after a GRUB fallback) and `autovalidate`
  (`nerves_fw_autovalidate=1` shipped default; set 0 for NervesHub-style
  explicit validation). `revert` now writes the pre-validated grubenv.
- **DSP/GPU/video firmware vendored**: `blobs/qcom-dsp-firmware/` now
  carries the redistributable linux-firmware set (board cdsp/adsp +
  Kodiak fallbacks, Adreno zap/SQE/GMU, Venus, QUP). CDSP version matches
  the pinned DSP shell (CDSP.HT.2.5.c4-00004-KODIAK-1). No manual harvest
  step remains.
- **Networking/USB/peripherals**: kernel fragment now enables GbE
  (r8169 + QMP PCIe PHY), NVMe, USB host (dwc3-qcom/XHCI + both USB
  PHYs, storage/HID, USB-NIC modules), GENI I2C/SPI/QSPI + GPI DMA,
  QSPI NOR, board RTC (m41t80), PMIC ADC/thermal zones, LMH, cpufreq,
  LEDs/pwrkey, and pins QRTR=y (guards the CDSP chain against silent
  =m demotion). GPU/display/Venus/AudioReach enabled as modules.
- **WiFi 6 + BT**: new `package/aic8800` builds Radxa's AIC8800D80 USB
  vendor driver (pinned commit, debian patch series applied) + firmware;
  `wpa_supplicant`/`wireless-regdb`/`iw` added for `vintage_net_wifi`.
- **Fixes**: `fwup-ops.conf` partition layout was out of sync with
  `fwup.conf` (3 GiB vs 2 GiB slots — `factory-reset`/`prevent-revert`
  would have trimmed the wrong regions); stale "Orange Pi 6" header.

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
