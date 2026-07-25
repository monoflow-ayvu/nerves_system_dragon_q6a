# Radxa Dragon Q6A - Nerves System

Custom [Nerves](https://nerves-project.org/) system for the
[Radxa Dragon Q6A](https://docs.radxa.com/en/dragon/q6a) (Qualcomm
**QCS6490**, Kryo 670 = 4×A78 + 4×A55), with the Hexagon **NPU** userspace
(FastRPC + DSP shell + optional QAIRT/QNN) vendored in so the CDSP stack is
present and version-matched at first boot.

| Feature | Description |
| --- | --- |
| CPU | Qualcomm QCS6490 (QCM6490 family; sc7280 mainline lineage) |
| Linux kernel | 6.18.0 (Deka `linux-dragon-q6a`, mainline + minimal board patches) |
| Boot | on-board Qualcomm UEFI → GRUB (arm64-efi) on ESP → A/B squashfs slots with auto-rollback |
| Console | debug UART `ttyMSM0`, 115200 8N1 |
| NPU | Hexagon CDSP via FastRPC/remoteproc/GLINK; DSP firmware + shell + libs pre-installed |
| Storage | microSD / UFS / eMMC (same image; A/B + app data partition); NVMe on M.2 |
| Ethernet | GbE (Realtek RTL8111 on PCIe, `r8169` built in) |
| WiFi/BT | WiFi 6 + BT 5.4 (Aicsemi AIC8800D80 on USB, vendor driver `package/aic8800`) + `wpa_supplicant` for `vintage_net_wifi` |
| USB | dual XHCI hosts (dwc3), USB storage/HID, common USB-NIC drivers |
| Extras | GPU/display (drm/msm + DP→HDMI bridge), Venus video, AudioReach audio - all as modules; RTC, thermal zones, cpufreq |

> Status: boot chain + A/B rollback are QEMU-validated. On-board
> validation (NPU `fastrpc_test -a v68`, Ethernet/WiFi/USB) is pending
> bench time - see `BRINGUP.md`. All firmware blobs are vendored; no
> manual harvest step remains.

## Boot architecture

The QCS6490 does **not** use U-Boot. Its ROM boots signed Qualcomm firmware
from on-board QSPI NOR:

```
PBL (ROM) → XBL/XBL_SEC → Qualcomm UEFI → <EFI payload on ESP> → kernel
```

We only replace the payload above UEFI. The UEFI firmware loads
`\EFI\BOOT\BOOTAA64.EFI` from the ESP - that's **GRUB 2** (built by
Buildroot for `arm64-efi`). GRUB:

1. reads `/EFI/BOOT/grubenv` to select the active A/B slot, then
2. loads the kernel (`/boot/Image`) from inside that slot's squashfs.

Kernel and rootfs therefore always upgrade together with the slot. The
kernel boots with `root=PARTUUID=...` probed from whichever disk GRUB was
loaded from, so one image works from microSD, UFS or USB. There is no
initrd: everything needed to mount the squashfs root (SD/UFS, squashfs) and
to bring up the CDSP (FastRPC/remoteproc/GLINK) is built into the kernel.

**The device tree comes from the firmware, not from us.** The SPI-NOR EDK2
compiles the board DTS at build time and publishes the DTB through the EFI
Configuration Table (`EFI_DEVICE_TREE_GUID`); on arm64 GRUB forwards it to
the kernel automatically so long as no `devicetree` command is issued. We
must use it: it carries runtime fixups a statically built DTB cannot have -
the memory map and reserved-memory carveouts that have to agree with what
XBL/TZ already established. Overriding it does not fail cleanly, it shows up
as SMMU faults or ADSP/CDSP remoteproc load failures. The DTB we build is
kept at `/usr/share/dtb/` purely as a bench reference to diff against
`/sys/firmware/devicetree/base`.

Structurally this follows `nerves_system_x86_64_uefi` /
`nerves_system_orangepi6` (GRUB-on-ESP, A/B slots in `grubenv`, a
u-boot-format KV block used only as a provisioning data store - no U-Boot
involved).

### A/B updates with automatic rollback

`grubenv` on the ESP carries `boot`/`validated`/`booted_once`, and
`grub.cfg` implements real **boot-once** semantics (which upstream
`nerves_system_x86_64` scaffolds but never wired up):

1. `fwup` upgrade writes the new slot's rootfs first and flips `grubenv`
   last (`validated=0 booted_once=0`), so an interrupted update never
   points GRUB at a half-written slot.
2. On the next boot GRUB marks `booted_once=1` (`save_env`) and gives the
   new slot exactly one try.
3. If that boot never validates, the *following* boot falls back to the
   previous slot and re-marks it valid. `qcom-coldplug.sh` then runs
   `fwup -t reconcile` to sync `nerves_fw_active` with the slot that
   actually booted.
4. Validation is the **application's** job. `nerves_fw_autovalidate=0` is
   the shipped default, so nothing validates before the BEAM is up.
   `Nerves.Runtime.StartupGuard` (enabled in `example/config/target.exs`,
   with `HEART_INIT_TIMEOUT` in `rel/vm.args.eex`) waits for every expected
   OTP application to start and then calls
   `Nerves.Runtime.validate_firmware/0`. A release that crash-loops or
   whose applications never start is therefore never validated, and the
   next reboot rolls back.

   Set `nerves_fw_autovalidate=1` for a headless image with no
   application-layer health signal: `qcom-coldplug.sh` then validates via
   `fwup -t autovalidate` at erlinit's pre-run hook, as before. Note this
   only proves the kernel booted — it cannot catch a bad release.

5. An upgrade is **refused** while the running slot is still an
   unvalidated trial, so one bad deployment cannot overwrite the last
   known-good slot and leave both unbootable.

On-device revert/validate/factory-reset live in `/usr/share/fwup/ops.fw`
(`fwup-ops.conf`); `revert` writes the target slot's *pre-validated*
grubenv since a previously-run slot is known good.

## NPU stack (Hexagon CDSP)

Four Buildroot packages under `package/` assemble the userspace the task
requires:

| Package | Contents | Source |
| --- | --- | --- |
| `qcom-fastrpc` | `libcdsprpc`/`libadsprpc`, `cdsprpcd`, `fastrpc_test` | qualcomm/fastrpc (autotools, from source) |
| `qcom-dsp-shell` | `fastrpc_shell_unsigned_3` + skels → `/usr/lib/dsp` | linux-msm/hexagon-dsp-binaries (`qcs6490/radxa/dragon-q6a`) |
| `qcom-dsp-firmware` | `cdsp.mbn`/`adsp.mbn`, GPU zap/SQE/GMU, Venus, QUP fw → `/lib/firmware/qcom/...` | upstream linux-firmware (redistributable; vendored in `blobs/`) |
| `qairt-runtime` | QNN/HTP libs (enabled in `nerves_defconfig`) | Qualcomm QAIRT SDK (local drop-in) |

Runtime plumbing (no systemd on Nerves - `rootfs_overlay/`):
`qcom-coldplug.sh` (erlinit `--pre-run-exec`) starts udev, `chmod 0666`s
`/dev/fastrpc-*` + `/dev/dma_heap/*` (also via `99-qcom-npu.rules`), and
launches `cdsprpcd`. `DSP_LIBRARY_PATH`/`ADSP_LIBRARY_PATH=/usr/lib/dsp` are
baked into `/etc/erlinit.config`.

### DSP firmware provenance

The signed `cdsp.mbn`/`adsp.mbn` are vendored in `blobs/qcom-dsp-firmware/`
from **upstream linux-firmware** (Radxa contributed the board-specific set;
marked Redistributable, see `LICENSE.qcom`/`NOTICE.qcom` there). No manual
harvest is needed. **Version rule:** `cdsp.mbn` and the shipped
`fastrpc_shell_unsigned_3` must carry the same build version string
(currently `CDSP.HT.2.5.c4-00004-KODIAK-1` on both), or
`FASTRPC_IOCTL_INIT_CREATE` fails with `0x80000600`.

The full frozen version tuple is in `GOAL.md`.

## Connectivity (Ethernet / WiFi / Bluetooth / USB)

- **Ethernet**: Realtek RTL8111 on `pcie0`; `r8169` + the QMP PCIe PHY are
  built into the kernel, so `eth0` is available at boot for
  `vintage_net_ethernet`.
- **WiFi 6 + BT 5.4**: onboard Aicsemi AIC8800D80 (Quectel FCU760K) on
  USB. `package/aic8800` builds Radxa's vendor driver (pinned commit,
  their debian patch series applied - it carries the ≥6.x kernel compat
  fixes) into `aic_load_fw`/`aic8800_fdrv`/`aic_btusb` modules, loaded by
  udev on enumeration, plus firmware in `/lib/firmware/aic8800_fw/USB/`.
  `wpa_supplicant` (nl80211, AP, WPA3, EAP), `wireless-regdb` and `iw` are
  in the image for `vintage_net_wifi`. The BT interface registers a BlueZ
  HCI (usable from Elixir with BlueHeron); stock `btusb` is deliberately
  **not** built so it can't grab the interface first.
- **USB**: both dwc3 controllers in host mode (XHCI), USB storage/UAS/HID
  built in, common USB NICs (CDC-ECM/NCM, RTL8152, AX88179) as modules.
- **Not in the DTS** (so not supported): WCN6750/ath11k - the board's WiFi
  really is the USB module.

## Building

Host is assumed to be non-FHS (NixOS); the system builds inside a Docker
build runner (`Dockerfile`, OTP 28 to match `BR2_PACKAGE_ERLANG_28=y`).

```sh
mix deps.get
mix compile        # builds the whole Buildroot system inside the container
```

`shell.nix` provides the host Elixir/OTP + `fwup`/`mtools`/`gptfdisk` for
building applications and running the QEMU test:

```sh
nix-shell --run "mix compile"
```

## Using

In your Nerves project's `mix.exs`:

```elixir
{:nerves_system_dragon_q6a, path: "../nerves_system_dragon_q6a", runtime: false, targets: :dragon_q6a}
```

Then `MIX_TARGET=dragon_q6a mix firmware && mix firmware.burn`. Serial
console: debug UART, 115200 8N1.

## QEMU smoke test (no board needed)

The kernel has virtio built in, so the same `Image` boots QEMU `-M virt`.
`test/qemu-smoke.sh` builds `example/`, assembles a disk image with `fwup`,
swaps in a QEMU `grub.cfg` (ttyAMA0, firmware-provided DTB), boots EDK2 →
GRUB → kernel → erlinit, and asserts it reaches the **IEx console**:

```sh
./test/qemu-smoke.sh
```

It re-execs itself inside `nix-shell -p qemu fwup mtools` if those tools
aren't on `PATH`. What it proves: UEFI+GRUB slot selection, squashfs kernel
load, kernel→erlinit→BEAM→IEx. What it can't prove: the Hexagon DSP (no
silicon under QEMU) - that's the bench acceptance test.

## Recovery

A bad ESP means EDL recovery (bottom of the boot chain is signed vendor
firmware). See `BRINGUP.md` for the EDL procedure and the bench playbook.
