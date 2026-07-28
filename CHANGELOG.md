# Changelog

## v0.6.1

Patch release with no functional system changes (same `package_files`
content as v0.6.0); exists to exercise the CI ccache warm-build path
end to end.

- Example: ortex pinned by git tag (`v0.2.0-rc.2`) instead of a raw
  commit ref.
- Repo: Renovate configured.

## v0.6.0

Bringing the system to parity with the hardware-proven `radxa-q6a-yocto`
reference. See `PORTING-FROM-YOCTO.md` for the full comparison and
`PORTING-FINDINGS.md` for the raw findings.

- **Rootfs A/B slots grown 2 GiB → 4 GiB** (`fwup.conf`,
  `fwup-ops.conf`). BREAKING for deployed devices: fwup only writes the
  GPT in the `complete` task, so an OTA upgrade keeps the old 2 GiB
  on-disk layout while the new firmware assumes 4 GiB offsets — a
  subsequent upgrade would trim/write at the wrong offsets. Devices
  flashed with ≤ v0.5.4 MUST be re-flashed (`fwup -t complete` /
  `install-to-disk.sh`); do NOT OTA them to this release.
  `test/qemu-smoke.sh` / `test/qemu-rollback.sh` `DISK_SIZE` default
  raised 6144 → 9216 MiB to fit the new layout.

- **Use the firmware-provided device tree** (B1). `grub.cfg` no longer
  issues a `devicetree` command. The board's SPI-NOR EDK2 compiles the
  board DTS and publishes the DTB via the EFI configuration table
  (`EFI_DEVICE_TREE_GUID`); on arm64 GRUB forwards it to the kernel
  automatically when no `devicetree` is issued. Our previous behaviour
  *replaced* that DTB wholesale, discarding the firmware's runtime fixups
  (memory map and reserved-memory carveouts that must agree with what
  XBL/TZ set up), which surfaces as SMMU faults or ADSP/CDSP remoteproc
  load failures rather than a clean error. The hardware-proven Yocto image
  installs no device tree at all. The DTB we build is still produced and is
  now installed at `/usr/share/dtb/` as a bench reference for diffing
  against `/sys/firmware/devicetree/base`. This also removes the
  Secure-Boot-must-be-off constraint, which only ever applied to
  `devicetree`.

## v0.5.4

- **QEMU tests: `-cpu cortex-a76` instead of `-cpu max`** (overridable
  via `QEMU_CPU`). QEMU 8.2 on ubuntu-24.04 aborts with `-cpu max`
  booting kernel 6.18 ("regime_is_user: code should not be reached"
  when the kernel enables hardware dirty-bit management). cortex-a76
  matches the real target and boots fine on QEMU 8.2 and 10.x — this
  is what killed the v0.5.3 release run.

## v0.5.3

- **Fix A/B bookkeeping never running on-target** (caught by the first
  real run of `test/qemu-rollback.sh` — v0.4.0 was never pushed, so CI
  had never executed it): the nerves-common busybox has no `command`
  builtin (`ASH_CMDCMD` off), so `command -v fwup` in
  `qcom-coldplug.sh` failed and silently skipped the
  reconcile/autovalidate fwup calls every boot. GRUB fallback worked,
  but `nerves_fw_active`/`nerves_fw_validated` never re-synced. Now the
  script probes `[ -x /usr/bin/fwup ]` and calls fwup by absolute path;
  `busybox.fragment` also enables `CONFIG_ASH_CMDCMD`. Full rollback
  test passes locally (11/11).
- **CI: qemu-smoke on ubuntu-24.04** (QEMU 8.2). QEMU 6.2's distorted
  TCG clock stalled the app-partition format and made the app-banner
  check non-fatal.

## v0.5.2

The build-system action has its own `mix hex.build` validation step —
same 16 MiB cap as v0.5.1 fixed in get-br-dependencies. Both now run
with `hex-validate: false`. v0.5.1's tag produced no release and can
be deleted.

## v0.5.1

Same content as v0.5.0, whose release run died packaging the hex
tarball (`mix hex.build` 16 MiB cap vs 47 MB of vendored blobs — first
tag since the blobs landed). CI now skips hex validation
(`hex-validate: false`); this system ships via GitHub Releases only.
The v0.5.0 tag produced no release and can be deleted.

## v0.5.0

Multimedia userspace (kernel + firmware side shipped in v0.4.0, which
was never tagged — its changes ship with this release too):

- **GPU**: Mesa freedreno (Adreno 643) with EGL/GLES2/GBM for KMS
  fullscreen rendering; `kmscube` + libdrm `modetest` for bring-up.
- **Audio**: alsa-lib + alsa-utils (aplay/amixer/alsactl/alsaucm/
  speaker-test). No UCM profiles for the WCD938x yet — mixer routing
  needs manual setup.
- **Video**: GStreamer (base/good/bad + libav) with `v4l2*` elements
  for Venus HW decode/encode and `kmssink` zero-copy display, plus
  the `ffmpeg` CLI (GPL, all codecs, `*_v4l2m2m` HW codecs) and
  `v4l2-ctl`. gst-gl intentionally skipped (needs X11/Wayland).
- **Webcams**: UVC pinned in the kernel fragment (`USB_VIDEO_CLASS=m`
  + media USB/camera support) instead of trusting the arch defconfig;
  gst `jpegdec` added for MJPEG capture (USB mics already covered by
  `SND_USB_AUDIO=m`).

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
