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
| Boot | on-board Qualcomm UEFI → GRUB (arm64-efi) on ESP → A/B squashfs slots |
| Console | debug UART `ttyMSM0`, 115200 8N1 |
| NPU | Hexagon CDSP via FastRPC/remoteproc/GLINK; DSP firmware + shell + libs pre-installed |
| Storage | microSD / UFS / eMMC (same image; A/B + app data partition) |

> Status: boot chain is QEMU-validated. On-board NPU validation
> (`fastrpc_test -a v68`) is pending bench time and one blob harvest - see
> **NPU stack** and `BRINGUP.md`.

## Boot architecture

The QCS6490 does **not** use U-Boot. Its ROM boots signed Qualcomm firmware
from on-board QSPI NOR:

```
PBL (ROM) → XBL/XBL_SEC → Qualcomm UEFI → <EFI payload on ESP> → kernel
```

We only replace the payload above UEFI. The UEFI firmware loads
`\EFI\BOOT\BOOTAA64.EFI` from the ESP - that's **GRUB 2** (built by
Buildroot for `arm64-efi`). GRUB:

1. reads `/EFI/BOOT/grubenv` to select the active A/B slot,
2. installs the board device tree with its `devicetree` command
   (`/boot/qcs6490-radxa-dragon-q6a.dtb`, loaded from *inside* the slot's
   squashfs), then
3. loads the kernel (`/boot/Image`) from the same squashfs.

Kernel, DTB and rootfs therefore always upgrade together with the slot. The
kernel boots with `root=PARTUUID=...` probed from whichever disk GRUB was
loaded from, so one image works from microSD, UFS or USB. There is no
initrd: everything needed to mount the squashfs root (SD/UFS, squashfs) and
to bring up the CDSP (FastRPC/remoteproc/GLINK) is built into the kernel.

This mirrors how **Armbian** boots the same board (its `qcs6490` kernel
family uses `grub-with-dtb` and `SERIALCON=ttyMSM0`), and structurally
follows `nerves_system_x86_64_uefi` / `nerves_system_orangepi6`
(GRUB-on-ESP, A/B slots in `grubenv`, a u-boot-format KV block used only as
a provisioning data store - no U-Boot involved).

**Secure Boot must be off** in the UEFI setup menu: GRUB disables its
`devicetree` command under Secure Boot.

### A/B failback

GRUB-side, identical to `nerves_system_x86_64`: `grubenv` carries
`boot`/`validated`/`booted_once`. `fwup` writes the new slot's rootfs first
and flips the active `grubenv` last, so an interrupted update never points
GRUB at a half-written slot. On-device revert/validate/factory-reset live
in `/usr/share/fwup/ops.fw` (`fwup-ops.conf`).

## NPU stack (Hexagon CDSP)

Four Buildroot packages under `package/` assemble the userspace the task
requires:

| Package | Contents | Source |
| --- | --- | --- |
| `qcom-fastrpc` | `libcdsprpc`/`libadsprpc`, `cdsprpcd`, `fastrpc_test` | qualcomm/fastrpc (autotools, from source) |
| `qcom-dsp-shell` | `fastrpc_shell_unsigned_3` + skels → `/usr/lib/dsp` | linux-msm/hexagon-dsp-binaries (`qcs6490/radxa/dragon-q6a`) |
| `qcom-dsp-firmware` | `cdsp.mbn` / `adsp.mbn` → `/lib/firmware/qcom/...` | **Phase-0 harvest** (see below) |
| `qairt-runtime` | QNN/HTP libs (optional, off by default) | Qualcomm QAIRT SDK (local drop-in) |

Runtime plumbing (no systemd on Nerves - `rootfs_overlay/`):
`qcom-coldplug.sh` (erlinit `--pre-run-exec`) starts udev, `chmod 0666`s
`/dev/fastrpc-*` + `/dev/dma_heap/*` (also via `99-qcom-npu.rules`), and
launches `cdsprpcd`. `DSP_LIBRARY_PATH`/`ADSP_LIBRARY_PATH=/usr/lib/dsp` are
baked into `/etc/erlinit.config`.

### The one manual step: `cdsp.mbn`

`hexagon-dsp-binaries` ships the DSP **shell** and skels but **not** the
signed `cdsp.mbn` firmware image. That must be harvested once from a stock
RadxaOS boot and dropped into `blobs/qcom-dsp-firmware/` (see that dir's
`README.md`). Until then the build still succeeds (fine for QEMU) but the
CDSP will not come up on hardware. **Version rule:** the harvested
`cdsp.mbn` and the shipped `fastrpc_shell_unsigned_3` must carry the same
build version string, or `FASTRPC_IOCTL_INIT_CREATE` fails with
`0x80000600`.

The full frozen version tuple is in `GOAL.md`.

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
