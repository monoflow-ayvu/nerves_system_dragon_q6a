# Changelog

## v0.10.5

**v0.10.4's venus patch is withdrawn** — hardware validation on the
Dragon Q6A showed that collapsing the VPU without the firmware's
prepare-power-collapse handshake leaves the core unbootable on the next
resume (`failed to reset venus core` in `venus_boot_core()`, until
reboot). This release replaces it with the pre-decided fallback:
disable runtime suspend entirely on the no-TZ path. Still the v0.9.5
tree plus kernel patches. OTA from any v0.6.x+ is safe.

- **Kernel: venus never power-collapses on no-TZ** — patch
  `0001-media-venus-never-collapse-vpu-on-no-tz.patch` makes
  `venus_runtime_suspend()` a no-op when `!core->use_tz`. The VPU stays
  powered across sessions, so both known wedge vectors become
  unreachable: the intermittent idle-poll `-ETIMEDOUT` in
  `venus_suspend_3xx()` and the resume-after-collapse boot failure.
  Resume needs no firmware handshake (`venus_power_on()` no-ops while
  `power_enabled`). Power saving is explicitly not required.
- **Boot-time probe caveat (board finding, app-side workaround)**: on
  this board the VPU ARM9 does not answer `VIDC_CTRL_INIT` when venus
  autoloads at ~5.5 s after boot (probe fails with
  `failed to reset venus core`, and the half-probed device is
  unrecoverable until reboot). Loading venus later (e.g. on first use)
  probes cleanly. The example app ships
  `rootfs_overlay/etc/modprobe.d/venus-debug-blacklist.conf` to
  suppress boot autoload — production apps should load venus on demand
  after boot (modprobe.d blacklist blocks autoload only; explicit
  `modprobe venus-core` still works).

## v0.10.4

**v0.10.0–v0.10.3 (iris/Gen2 VPU) were reverted as a dead end** — on this
board's KODIAKWP firmware, TrustZone rejects all Linux PIL calls for the
video peripheral, so the iris backport can never load firmware; their tags
and releases remain as the documented failed experiment. This release is
the v0.9.5 tree (byte-identical) plus one kernel patch carrying the Tier-1
venus wedge fix. OTA from any v0.6.x+ is safe.

- **Kernel: venus no-TZ wedge fix** — patch
  `0001-media-venus-skip-idle-check-on-no-tz-suspend.patch`. On the no-TZ
  boot path (`use_tz=false`), the VPU firmware does not reliably report
  WFI/idle at session teardown, so the idle poll in `venus_suspend_3xx()`
  intermittently timed out (-110) and wedged the VPU until reboot. The
  power-collapse/resume machinery itself is proven on this board, so the
  idle check is now skipped on no-TZ systems and collapse is unconditional
  (same shape as the older `venus_suspend_1xx` flow). v0.9.5 behavior
  otherwise.

## v0.9.5

- **ffmpeg text overlays (drawtext)** — `BR2_PACKAGE_FREETYPE=y`
  (ffmpeg.mk auto-enables `--enable-libfreetype` on glibc), plus
  `libfribidi` (bidi/RTL) and `harfbuzz` (complex-script shaping) for the
  `drawtext` filter. Ships **DejaVu Sans** (`BR2_PACKAGE_DEJAVU_SANS`) as
  the image's only font — there is no fontconfig, so use
  `drawtext=fontfile=/usr/share/fonts/dejavu/DejaVuSans.ttf:...`.

## v0.9.4

**v0.9.3's kernel side was empty — do not use it for WireGuard.** The
`depends on IPV6 || !IPV6` on the driver is not a tautology in Kconfig
tristate logic (`!m == m`), so with the base defconfig's `CONFIG_IPV6=m`,
`olddefconfig` silently demoted `CONFIG_WIREGUARD=y` to `=m`, which built
nothing (no module, no modalias to autoload). v0.9.3 shipped `wg` userspace
but no kernel support; 0.9.4 fixes the kernel side. Layout unchanged since
v0.6.0 — OTA from any v0.6.x+ is safe.

- **Kernel: `CONFIG_IPV6=y` + `CONFIG_WIREGUARD=y`** — verified against the
  pinned kernel that the merged config keeps both through `olddefconfig`.
  WireGuard is builtin so `ip link add wg0 type wireguard` works with no
  module-load ordering dependency.
- **Userspace: `wg` (no `wg-quick`)** — the image has no bash (busybox
  only), and wireguard-tools' Makefile auto-disables wg-quick without
  bash. Plain `wg` is the full client-configuration path.

## v0.9.3

WireGuard VPN support — kernel and userspace. Layout unchanged since
v0.6.0 — OTA from any v0.6.x+ is safe.

- **Kernel: `CONFIG_WIREGUARD=y`** (builtin) in `linux-dragon-q6a.fragment`.
  Builtin rather than a module so `ip link add wg0 type wireguard` always
  works regardless of module-autoload ordering; Kconfig deps verified
  against the pinned kernel (NET+INET =y, everything else selected, so the
  symbol cannot be silently demoted).
- **Userspace: `BR2_PACKAGE_WIREGUARD_TOOLS=y`** — `wg` + `wg-quick`
  (1.0.20260223) for configuring client tunnels.

## v0.9.2

QNN GPU backend vendored into the image, for completeness and future
OpenCL bring-up. Layout unchanged since v0.6.0 — OTA from any v0.6.x+
is safe.

- **`libQnnGpu.so` added to `/usr/lib/onnxruntime-qnn/`** — the QNN GPU
  backend (Adreno via OpenCL), 8.9 MB from the `onnxruntime_qnn` 2.4.0
  aarch64 wheel, now installed alongside the HTP set. Note: it loads but
  cannot create a device until an OpenCL userspace exists — the image has
  no `libOpenCL.so` (no rusticl for freedreno, no vendor driver), so
  `Backend GPU: Not Found` in QNN logs remains expected.
- Docs: blobs README + `onnxruntime-qnn` Config.in updated to describe the
  full six-file set and the OpenCL caveat.

## v0.9.1

**The v0.9.0 prebuilt shipped without `qcom/a660_sqe.fw`** — the bare
`*.fw` gitignore silently excluded the vendored Adreno SQE microcode from
CI checkouts (the file existed only untracked on the build machine, so the
artifact checksum matched while the rootfs missed it). MSM logged
"Direct firmware load for qcom/a660_sqe.fw failed" and Turnip had no GPU
(`VK_ERROR_INITIALIZATION_FAILED`). If you flashed v0.9.0, upgrade.

- **Adreno SQE firmware now tracked + guarded**: `a660_sqe.fw` force-added
  (`b6b360d`) and a `.gitignore` negation keeps it out of the `*.fw` rule
  from now on. Verified on hardware: `vulkaninfo` enumerates Turnip
  Adreno 643 (API 1.3.348) and a compute-shader rotation runs (PASS).
- **ffmpeg Vulkan filters**: `BR2_PACKAGE_FFMPEG_VULKAN`
  (`--enable-vulkan`: `hwupload` + `*_vulkan` filters, GLSL shader
  support) and `BR2_PACKAGE_VULKAN_HEADERS`, so ffmpeg can exercise the
  Adreno for the AI-branch rotate/transpose demo.

## v0.9.0

Vulkan userspace for the Adreno 643: Mesa Turnip + the Khronos ICD loader +
vulkaninfo. Kernel and firmware side shipped with v0.5.0 — the dmesg
`ops a3xx_ops` line that looked like a blocker is the kernel's generic
component-ops name used by every Adreno generation, not the GPU backend:
the pinned radxa/kernel binds this part through the modern a6xx path
(chip_id 0x06030500 → `a6xx_gpu_init`). Layout unchanged since v0.6.0 —
OTA from any v0.6.x/v0.7.x/v0.8.x is safe.

- **Vulkan: Mesa Turnip** (`BR2_PACKAGE_MESA3D_VULKAN_DRIVER_FREEDRENO`)
  — builds `libvulkan_freedreno.so` + the freedreno ICD json
  (`/usr/share/vulkan/icd.d/freedreno_icd.*.json`). The option is not in
  Buildroot 2026.05 (upstream added it after that release), so the symbol
  and the meson wiring live in this repo's external tree (`Config.in` +
  `external.mk`); drop both once nerves_system_br bumps past a Buildroot
  that ships it.
- **Vulkan loader + tools**: `vulkan-loader` + `vulkan-tools`
  (`vulkaninfo`). Render-node access was already in place (eudev gives
  `renderD*` 0666, Nerves runs as root). Acceptance check on the board:
  `vulkaninfo | grep deviceName` should list an Adreno 7c+/FD643 device.
- Docs: full kernel-compat evidence (a3xx_ops misdiagnosis, Turnip ioctl
  surface, FD643 chip match) in `WORKING_NOTES.md`.

## v0.8.0

HTTPS/TLS for ffmpeg, plus the HypervisorOverride OTA-killer fix that
slipped past v0.7.0. Layout unchanged since v0.6.0 — OTA from any
v0.6.x/v0.7.x is safe.

- **ffmpeg HTTPS/TLS**: `BR2_PACKAGE_GNUTLS=y` — buildroot's ffmpeg.mk
auto-enables `--enable-gnutls`, giving the ffmpeg CLI the `https`,
`tls`, `rtmps`, `wss` protocols (`ffmpeg -i https://…`). GnuTLS
(LGPL-2.1+/GPL-3 dual) is the license-clean TLS backend here: OpenSSL
is already in the image (Erlang `:ssl` via nerves-config) but is
GPL-incompatible with `BR2_PACKAGE_FFMPEG_GPL=y`, so ffmpeg.mk forces
`--disable-openssl`.
- **HypervisorOverride no longer reboots at boot (OTA-killer fix).**
v0.7.0's `qcom-uefi-vars.sh` rebooted right after writing the trigger —
which on the first boot of an unvalidated A/B slot (exactly a
v0.6.x → v0.7.0 OTA) spent GRUB's boot-once budget and rolled the
update back. The trigger needs no immediate reboot: the firmware
consumes it at the start of the next boot, after the app has validated
the slot (`Nerves.Runtime.StartupGuard`), so the firmware's own
apply-reboot is free.
- Docs: full UEFI variable inventory + Venus behavior matrix in
  `docs/BOARD_QUIRKS.md`.

## v0.7.0

Venus video (VPU) enablement plus software encoders. Layout unchanged
since v0.6.0 — OTA from any v0.6.x is safe.

- **Venus firmware fixed (M3).** `qcom/vpu-2.0/venus.mbn` now points at
  `vpu20_p1.mbn` (VPU-2.0 Gen1) instead of the VPU-1.0 `vpu20_p4.mbn`
  that PAS/TZ rejects — the driver died at core reset and no
  `/dev/video*` ever appeared. Decode through the VPU (MPEG-2/H.264)
  now works out of the box. `vpu20_p4.mbn` dropped (−1.9 MB/slot).
- **UEFI `HypervisorOverride` auto-enabled at boot**
  (`rootfs_overlay/usr/sbin/qcom-uefi-vars.sh`, run from
  `qcom-coldplug.sh`). Without it, any venus encode job hard-resets the
  SoC (PSHOLD warm reset from the hypervisor/TZ). With it, **H.264
  1080p VPU encode works at ~87 fps**. Still broken at venus firmware
  level: 720p H.264 and all HEVC encode stall with zero frames. The
  variable is a one-shot trigger (firmware applies it and resets the
  visible value to 0), so the script keys on a
  `/root/.hypervisor-override-requested@<bios_version>` marker and
  reboots once; `docs/BOARD_QUIRKS.md` §10 documents the full efivarfs
  procedure (4-byte attrs `NV|BS|RT` are part of the write, `chattr -i`
  first, single `write()`).
- **Software H.264/HEVC encode**: `x264` and `x265` packages added —
  ffmpeg auto-enables `libx264`/`libx265` (`FFMPEG_GPL=y`). Measured
  on-board with the previously shipped encoders: MPEG-4 1080p 87 fps,
  MPEG-2 94 fps. Fragmented MP4 needs no package: `mov` muxer with
  `-movflags frag_keyframe+empty_moov+default_base_moof`.
- **Downloads**: `BR2_PRIMARY_SITE="https://sources.buildroot.net"` —
  x265's upstream (bitbucket downloads) is dead and the nerves backup
  mirror 403s what it doesn't carry.
- Example: ortex pinned by tag (`v0.2.0-rc.2`) instead of a raw commit.

## v0.6.1

Patch release with no functional system changes; exists to exercise
the CI ccache warm-build path end to end. (The artifact checksum still
changes because VERSION is part of `package_files`.)

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
