# BRINGUP.md - Dragon Q6A bench playbook

The log of what to do the day the board is on the desk. Everything here is
blocked on hardware; the repo itself is validated in QEMU (see
`test/qemu-smoke.sh`). Fill in the "Observed" blanks as you go - they feed
the frozen tuple in `GOAL.md`.

## 0. Serial console first

Debug UART, **`ttyMSM0`, 115200 8N1**, 3.3 V. Confirm you see the XBL/UEFI
log before touching anything. The board DTS sets
`stdout-path = "serial0:115200n8"` (`serial0 = &uart5`).

## 1. EDL recovery (practice until boring)

Bottom of the boot chain is signed vendor firmware in QSPI NOR; a bad ESP
is recovered via **EDL**, not reflashing SD.

- **Enter EDL:** hold the button next to the headphone jack while powering
  on, connected to the host via the **USB 3 (Type-A) port** with a
  **Type-A ↔ Type-A** cable.
- **Tool:** [`edl-ng`](https://github.com/strongtz/edl-ng) (v1.4.1 used by
  the interfacinglinux write-up).
  ```sh
  wget https://github.com/strongtz/edl-ng/releases/download/v1.4.1/edl-ng-linux-x64.zip
  unzip edl-ng-linux-x64.zip
  # From within Radxa's firmware snapshot dir:
  sudo ./edl-ng --memory spinor --loader prog_firehose_ddr.elf rawprogram rawprogram0.xml patch0.xml
  ```
- Firmware snapshot + flashing docs: https://docs.radxa.com/en/dragon/q6a
  (firmware/EDL sections). Armbian notes the **latest UEFI firmware is
  required**.
- **Observed UEFI version string** (`QC_IMAGE_VERSION_STRING=BOOT...KODIAK...`
  from the boot log, or `cat /sys/class/dmi/id/bios_version` once booted):
  __________ → record in `GOAL.md`.
- **Minimum required (the M8 floor):**
  `6.0.260120.BOOT.MXF.1.0.1-00549-KODIAKWP-1`

  Older boot firmware makes QTEE reject **unsigned** DSP protection domains
  with `0x80000600`. QNN and `fastrpc_test -a v68` both need unsigned PD, so on
  an un-upgraded board the NPU is dead however correct everything else is — and
  it presents as a blob/version mismatch, sending you down the wrong path.
  **`0x80000600` has two causes: old SPI firmware, or a blob/shell mismatch.
  Check the firmware version first.** Upgrade before spending any time on
  §2 below.

## 2. Phase-0 NPU sanity check (blobs already vendored)

The DSP firmware is now vendored in `blobs/qcom-dsp-firmware/` from upstream
linux-firmware (board `cdsp.mbn` = `CDSP.HT.2.5.c4-00004-KODIAK-1`, matching
the pinned shell) - no harvest is required. A stock RadxaOS boot is still
the fastest way to cross-check the known-good tuple if anything misbehaves:

```sh
apt install fastrpc libcdsprpc1 fastrpc-test
# confirm it passes:
LD_LIBRARY_PATH=/usr/lib/fastrpc_test DSP_LIBRARY_PATH=/usr/share/fastrpc_test/v68 fastrpc_test -a v68
# harvest:
cp -a /lib/firmware/qcom/qcs6490/cdsp.mbn ~/harvest/
strings /lib/firmware/qcom/qcs6490/cdsp.mbn | grep -i KODIAK   # version string
dmesg | grep -iE "cdsp|fastrpc|remoteproc"                     # save this
cp /sys/firmware/fdt ~/harvest/stock.dtb                       # DTB in use
```

- **Observed cdsp.mbn version string:** __________
- If it matches `CDSP.HT.2.5.c4-00004-KODIAK-1`, the `qcom-dsp-shell` pin is
  already correct. If not, re-pin the shell in
  `package/qcom-dsp-shell/qcom-dsp-shell.mk` to the matching version, or use
  Olof's validated combo (generic upstream `qcm6490/cdsp.mbn` + matching
  RB3gen2 shell at the same string).
- The vendored blobs already carry the matching version; only revisit
  `blobs/qcom-dsp-firmware/` if the observed stock version differs.

Also confirm which device nodes exist and which domain the test uses:
```sh
ls -l /dev/fastrpc-*        # expect -adsp, -cdsp, maybe -cdsp-secure
```
CDSP = domain 3 = `-a v68`.

## 3. First flash of our image

```sh
cd example
MIX_TARGET=dragon_q6a mix firmware
MIX_TARGET=dragon_q6a mix firmware.burn   # to microSD
```

Insert SD, set the UEFI boot order to the SD, power on with serial attached.
Expect: GRUB "Booting slot A" → kernel 6.18 → IEx on `ttyMSM0`.

- If UEFI won't load `\EFI\BOOT\BOOTAA64.EFI` from removable media: check
  Secure Boot is off; if still no go, fall back to keeping Radxa's embloader
  on the ESP and generating BLS entries (documented fallback, not yet
  implemented).
- If the kernel hangs early: add `earlycon` to the cmdline in `grub.cfg`.

## 3b. B6 RESOLVED on hardware — GRUB's LoadImage path works

**Observed 2026-07-25: outcome 1 of the three B6 possibilities.** The board boots our image from
microSD: GRUB ran, the kernel loaded, erlinit came up, and its console message appeared **on the
HDMI screen**. No `cannot load image`, no silent ~30 s watchdog reset.

Consequences, all of which retire planned work:

- Firmware `LoadImage()` accepts our ~39 MiB `CONFIG_EFI_STUB` kernel. The EDK2
  `TrEE`/`MeasureBoot` abort that killed the Yocto project's 50 MiB UKI does **not** affect a plain
  arm64 `Image` loaded by GRUB. So the size theory was wrong and the PE-layout theory was right.
- **`CONFIG_EFI_ZBOOT` is not needed.** Do not apply it.
- **The systemd-boot port is not needed.** Keep GRUB.
- The HDMI framebuffer console works, so `console=tty1` + `CONFIG_SYSFB_SIMPLEFB=y` + `simpledrm`
  were correct — and since fbcon requires a real framebuffer, the EDK2 DTB does supply the
  `simple-framebuffer` node (q3). Confirm explicitly with the commands in §3c.

**Flash with `mix firmware.burn`, never by `dd`-ing `mix firmware.image` output.** A dd'd
`example.img` was **not offered as a boot device at all** — no GRUB, no rescue prompt. The image
itself was structurally valid (GPT, ESP `EF00`/`C12A7328-…`, FAT32, `/EFI/BOOT/BOOTAA64.EFI`,
grub prefix `/EFI/BOOT`), but it is a fixed 4.75 GiB image whose GPT hard-codes that geometry, so
on a larger card the backup GPT is no longer at the last LBA and `last_usable_lba` is wrong
(`fdisk` warns "The backup GPT table is not on the end of the device" / "GPT PMBR size mismatch").
EDK2 appears to reject that table outright. `fwup` writing straight to the device sizes the GPT to
the real medium and expands p4 (`fwup.conf:169`). To salvage an already-dd'd card:
`sudo sgdisk -e /dev/sdX`.

## 3b-2. WiFi + SSH working on hardware — 2026-07-26

`ssh nerves.local` over WiFi, confirmed on the board:

```
example 0.1.0 - emotion-van
  Serial       : 0048542164f6      Uptime  : 1 minutes and 51 seconds
  Firmware     : Valid (A)         Applications : 38 started
  Load average : 0.70 0.38 0.15    Temperature  : 32.8°C
  Hostname     : nerves-64f6       Platform     : dragon_q6a aarch64
  wlan0        : 192.168.1.33/24, 2804:…:352e/64, fe80::…:352e/64
```

What that one banner proves, beyond networking: **`Firmware: Valid (A)`** means StartupGuard ran on
real hardware and validated the slot after the app came up — B5's mechanism works end to end, not
just in QEMU. **`Temperature: 32.8°C`** means `QCOM_TSENS` is live. IPv6 SLAAC works alongside
IPv4. mDNS resolves, so `mix upload` OTA is now available and SD reflashing is no longer needed
for app changes.

Two fixes were needed to get here, both easy to lose:

1. **The AIC8800 driver must be rebuilt whenever the kernel version changes.** Buildroot does not
   rebuild out-of-tree kernel-module packages on a kernel bump — after the B7 switch the `.ko`
   files still sat under `/lib/modules/6.18.0/updates/` while the board ran 6.18.2, so
   `modprobe` found nothing. Symptoms were total silence: no `wlan0`, no `lsmod` entry, and not one
   `aic` line in `dmesg`. Fix: `make aic8800-dirclean` and rebuild.
2. **VintageNet needs policy routing** — `CONFIG_IP_ADVANCED_ROUTER=y` +
   `CONFIG_IP_MULTIPLE_TABLES=y`, now in `linux-dragon-q6a.fragment`. Without them the interface
   associates and DHCP succeeds, then `VintageNet.RouteManager` crash-loops on every route insert
   with `ip: RTNETLINK answers: Operation not supported`. VintageNet prints both symbol names in
   that error, so trust it.

## 3b-3. B2 verdict: SMMU fixed, GPU firmware fixed, display mode still open

**The -110/-19 failure mode is gone.** Making `SC_GPUCC_7280`/`SC_DISPCC_7280` builtin fixed the
adreno SMMU exactly as B2 predicted: `3d6a000.gmu: Adding to iommu group 1`, the GPU and
displayport-controller both bind, `msm` initialises.

**But builtin `DRM_MSM` could not load its firmware.** Measured:
```
[4.945598] Direct firmware load for qcom/a660_sqe.fw failed with error -2
[5.004336] VFS: Mounted root (squashfs filesystem) readonly
```
59 ms too early — builtin drivers probe during initcalls, `prepare_namespace()` mounts root after
`do_basic_setup()`, and `adreno_request_fw()` uses `request_firmware_direct()` which never retries.
The vendor avoids this by shipping an initramfs (`q6a-a.cpio.gz`); we have none.
Fix: `CONFIG_DRM_MSM=m`, keeping gpucc/dispcc/DRM builtin. Confirmed working:
```
[11.352676] loaded qcom/a660_sqe.fw from new location
[11.365799] loaded qcom/a660_gmu.bin from new location
[11.378082] [drm] Loaded GMU firmware v3.1.10
```
with no return of -110/-19. Side benefit: the shell comes up sooner, because msm no longer delays
the root mount.

**Display CONFIRMED WORKING at 1080p through msm's own modesetting:**
```
/sys/class/drm/card1-HDMI-A-1/status  -> connected
/sys/class/drm/card1-HDMI-A-1/modes   -> 1920x1080 (x3), 1024x768, 800x600, 640x480   (EDID read)
/sys/class/graphics/fb0/virtual_size  -> 1920,1080
/sys/class/graphics/fb0/name          -> msmdrmfb          (msm, NOT simpledrm)
```

**Known-cosmetic warnings — do NOT chase these:**
- `disp_cc_mdss_dp_pixel_clk_src: rcg didn't update its configuration.` +
  `WARNING at drivers/clk/qcom/clk-rcg2.c:136 update_config`, via
  `qmp_combo_configure_dp_clocks` → `msm_dp_ctrl_enable_mainlink_clocks`. The DP pixel-clock RCG
  fails to latch on the first attempt during PHY power-on, then succeeds: the console switches to
  a 240x67 (=1920x1072) framebuffer ~340 ms later and the mode list is correct. Same family as the
  upstream "delay applying clock defaults until PHY is fully enabled" work. Noise unless the mode
  list or fb size regresses.
- `[drm] Cannot find any crtc or sizes` (x2) is logged *before* HPD processing completes, i.e. a
  bring-up transient, not the end state. It is NOT evidence of a broken pipeline — check
  `fb0/name` and `modes` before believing it.
- `WARNING at kernel/module/kmod.c:143 __request_module`, via
  `phy_request_driver_module` ← `rtl_init_one`. r8169 is builtin and probes in async context, so
  `request_module()` for the MDIO PHY warns. `CONFIG_REALTEK_PHY=y` is already builtin so the PHY
  binds anyway and eth0 works. This is what sets the sticky `Tainted: W` flag that then appears on
  every later trace -- do not attribute `W` on an unrelated stack to that stack.
- `aicwf_usb_disconnect` / `aicwf_bus_deinit` around WiFi init is the AIC8800's normal two-stage
  bring-up: `aic_load_fw` pushes firmware, the device re-enumerates, then `aic8800_fdrv` binds.
- `fb0: sys_imageblit/sys_fillrect: framebuffer is not in virtual address space` — fbdev emulation
  draws via a shadow buffer. Harmless, but it makes console scrolling slow, which is worth
  remembering before blaming boot time on something else while `loglevel=7` is set.

**Still open, in priority order:**
1. `qcom-venus aa00000.video-codec: probe … failed with error -110` — this is **M3** (wrong Venus
   blob), a different root cause from the GPU firmware issue. Do not conflate them. Note
   `venus_core` does load as a module; it is the probe that times out.
2. `gcc-sc7280`/`gpu_cc-sc7280: sync_state() pending due to 3d6a000.gmu` — likely benign: the gmu
   is claimed by the a6xx driver as a component rather than by its own platform_driver, so the
   driver core never marks it probed and `sync_state()` stays pending. Confirm it is harmless
   before spending time on it.

## 3c. Phase 0 data to capture now that it boots

```sh
cat /sys/class/dmi/id/bios_version            # q4/M8 floor: 6.0.260120.BOOT.MXF.1.0.1-00549-KODIAKWP-1
ls /sys/firmware/devicetree/base/             # q3: must be populated -> firmware DTB in use (B1)
grep -c simple-framebuffer /sys/firmware/fdt  # or: dtc -I fs /sys/firmware/devicetree/base | grep -A5 simple-framebuffer
dmesg | grep -iE "simpledrm|efifb|Machine model"
dmesg | grep -iE "adreno|msm|-110|-19"        # B2: display/GPU probe
cat /sys/class/remoteproc/*/state             # M7: expect "running"
ls -l /dev/tee0 /dev/fastrpc-*                # M11 / fastrpc
```
IEx is the only shell, so run these via `:os.cmd/1` or `System.cmd/2`.

## 4. Acceptance test (§9 of the task doc)

On a freshly flashed image, over serial, no manual setup:

1. Reaches IEx (Nerves runtime up). Already proven in QEMU.
2. `dmesg` shows `remoteproc ... cdsp.mbn ... remote processor cdsp is now up`
   and **no** `no reserved DMA memory for FASTRPC`.
3. `/dev/fastrpc-cdsp` exists 0666; `cdsprpcd` running (`Example.npu_status()`).
4. `fastrpc_test -a v68` → all PASS (hap_example, multithreading, calculator).
5. Stretch: `qnn-platform-validator` reports HTP usable (needs `qairt-runtime`).
6. A/B: `Nerves.Runtime.revert` flow works.

Invocation baked into the image env (`/etc/erlinit.config`,
`/etc/profile.d/qcom-npu-env.sh`): `DSP_LIBRARY_PATH=/usr/lib/dsp`. From a
shell: `fastrpc_test -a v68`.

## Observed versions (fill in)

| Component | Planned | Observed on bench |
| --- | --- | --- |
| UEFI firmware | latest Radxa snapshot | |
| Kernel | 6.18.2 (radxa/kernel 559f4f92) | |
| cdsp.mbn version string | CDSP.HT.2.5.c4-00004-KODIAK-1 | |
| fastrpc_shell_unsigned_3 | same as cdsp.mbn | |
| `fastrpc_test -a v68` | PASS | |
