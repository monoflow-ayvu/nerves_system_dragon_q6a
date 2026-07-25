# GOAL - nerves_system_dragon_q6a

Standing goal for autonomous work sessions. Keep iterating until every
"Definition of done (this repo, bench-free)" box is checked. Update the
checkboxes and the Worklog as progress is made. Do not stop at plans -
build, run, read the errors, fix, repeat.

## Mission

Custom Nerves system (Buildroot) for the **Radxa Dragon Q6A**
(Qualcomm QCS6490) with an **NPU-ready userspace**: a kernel carrying the
FastRPC/remoteproc/GLINK stack, driven by the firmware-supplied device tree
(reserved-memory regions come from the SPI-NOR EDK2 DTB), the Hexagon
CDSP firmware + DSP shell + FastRPC userspace pre-installed and
version-matched, booting through the board's native Qualcomm UEFI chain
into BEAM-as-init.

**Headline success (user-set, bench-free):** a firmware image that boots in
QEMU and shows the **IEx console + Nerves login shell** over serial. This is
the gate for this session - get the full UEFI→GRUB→kernel→erlinit→IEx chain
green in emulation.

Final on-board acceptance (needs the physical bench, §9 of the task doc):
`fastrpc_test -a v68` passes over serial on first boot. Everything that can
be validated *without* the board must be validated here first.

## Definition of done (this repo, bench-free)

- [x] Repo skeleton complete (mix.exs, nerves_defconfig, fwup.conf,
      fwup-ops.conf, grub.cfg, post-build/post-createfs, overlay,
      Dockerfile, shell.nix), modeled on `../nerves_system_orangepi6`.
- [x] Kernel pinned by commit SHA (Deka `linux-dragon-q6a` @ e05c4fa),
      config carries the FastRPC stack (`QCOM_FASTRPC`, `QCOM_Q6V5_PAS`,
      GLINK, SMEM, dmabuf heaps, UFS/SD, sc7280 clk/pinctrl/interconnect,
      SMMU) **and** virtio (blk/net/pci) - same kernel boots QEMU. Built OK.
- [x] DTB `qcs6490-radxa-dragon-q6a.dtb` built; DTS verified to declare
      CDSP/ADSP reserved-memory + `qcom,fastrpc` glink nodes (compute-cb
      context banks). No patch needed. NOT loaded at boot: the SPI-NOR EDK2
      supplies the DTB via the EFI configuration table and grub.cfg issues
      no `devicetree`. Ours is kept at /usr/share/dtb for bench diffing.
- [x] Buildroot packages: `qcom-dsp-firmware` (harvest drop-in),
      `qcom-dsp-shell` (`fastrpc_shell_unsigned_3` + skels),
      `qcom-fastrpc` (built from source: libcdsprpc/libadsprpc/cdsprpcd/
      fastrpc_test), `qairt-runtime` (optional, off). All build clean.
- [x] Runtime plumbing in rootfs_overlay: udev 0666 rules for
      `/dev/fastrpc-*` + `/dev/dma_heap/*`, coldplug chmod + cdsprpcd
      launch, `DSP_LIBRARY_PATH`/`ADSP_LIBRARY_PATH` baked into erlinit.
- [x] `mix compile` (Docker build runner) completes; system artifact
      produced.
- [x] Example app in `example/` builds a `.fw` (67 MB).
- [x] **QEMU smoke test passes** (`test/qemu-smoke.sh`): EDK2 aarch64 →
      GRUB (BOOTAA64.EFI, slot A from grubenv) → kernel 6.18 out of
      squashfs → erlinit → **IEx prompt** (Elixir 1.19.5 / OTP 28) on
      ttyAMA0. App-data partition auto-formats + mounts r/w on first boot
      (Nerves.Runtime.Init). All 5 checks PASS.
- [x] rootfs carries the NPU file map (firmware path, /usr/lib/dsp shells,
      fastrpc libs + fastrpc_test) at the harvested paths.
- [x] README.md documents boot design + frozen version tuple;
      BRINGUP.md has the bench playbook (EDL recovery, serial, first
      flash, fastrpc_test).

**Headline goal - MET (2026-07-03):** bootable image shows the IEx console
+ Nerves login shell in QEMU. Evidence: `test/qemu-run.trimmed.log`.

## Bench follow-ups (blocked on hardware, do NOT block this repo)

- Phase 0 harvest from stock RadxaOS (known-good tuple archive) - until
  then the tuple comes from linux-msm/hexagon-dsp-binaries + Olof's
  validated combination.
- Real-board boot of the .fw, `fastrpc_test -a v68` PASS, A/B revert demo.
- qnn-platform-validator (stretch).

## Design decisions (record here as they're made)

- **Template:** `nerves_system_orangepi6` (same author, aarch64 UEFI+GRUB
  Nerves system, NPU blob packages, QEMU two-stage test) - much closer
  than `nerves_system_x86_64_uefi`.
- **Boot:** on-board Qualcomm UEFI → `\EFI\BOOT\BOOTAA64.EFI` (GRUB2
  arm64-efi from Buildroot) on ESP → `load_env` A/B slot select →
  `linux` loaded **from inside the slot's squashfs** (`/boot/Image`) so
  kernel+rootfs upgrade atomically. The DTB comes from the SPI-NOR EDK2 via
  the EFI configuration table; grub.cfg installs none.
  Fallback if UEFI won't load GRUB: keep
  Radxa's embloader on the ESP and generate BLS entries instead
  (documented in README, not implemented unless needed).
- **A/B failback:** GRUB-side (grubenv booted_once/validated flags),
  identical to orangepi6/x86_64 model. No nerves_initramfs.
- **Provisioning KV store:** fwup uboot-env block at LBA 64 (raw region,
  not a partition), same as orangepi6.
- **Docker build runner** (host is NixOS): `Dockerfile` pins OTP 28 +
  Elixir to match `BR2_PACKAGE_ERLANG_28=y`.
- **QEMU:** same kernel binary boots `-M virt` via virtio (config adds
  virtio) - full-chain validation without the board.

## Frozen version tuple (update when anything moves)

| Component | Version / pin |
| --- | --- |
| nerves_system_br | 1.34.0 (Buildroot 2026.05) |
| Toolchain | nerves_toolchain_aarch64_nerves_linux_gnu 15.3.0 (glibc) |
| Erlang/OTP (target+host) | 28 (28.5.0.2) / Elixir 1.19.5 |
| Kernel | Deka `linux-dragon-q6a` branch `dragon-q6a-v6.18` @ `e05c4faeded00da418899bd7fb03be473ca18981` (mainline 6.18.0 + Dragon Q6A patches) |
| DTB | `qcom/qcs6490-radxa-dragon-q6a` (in-tree; includes mainline `sc7280.dtsi`, carries CDSP/ADSP remoteproc + `qcom,fastrpc` glink nodes) |
| DSP shell | linux-msm/hexagon-dsp-binaries @ `2ba83638…` → `qcs6490/radxa/dragon-q6a/CDSP.HT.2.5.c4-00004-KODIAK-1` (CDSP) + `ADSP.HT.5.5.c9-00028-KODIAK-2` (ADSP) |
| cdsp.mbn / adsp.mbn | Vendored in `blobs/qcom-dsp-firmware/` from upstream linux-firmware (`qcom/qcs6490/radxa/dragon-q6a/`, Redistributable). CDSP version matches the shell string above. |
| fastrpc userspace | qualcomm/fastrpc branch `development` @ `706071caca54b9a56d78793c30d04351de5fbd96` (autotools; deps libyaml, libbsd) |
| UEFI firmware (board-side, QSPI NOR) | record from bench boot log (Phase 0) |

### Research findings (2026-07-02, corroborated)

- **Boot design partly validated by Armbian:** their `qcs6490` kernel family
  uses the `grub-with-dtb` extension with `SERIALCON=ttyMSM0`.
  **SUPERSEDED (2026-07-25):** we no longer copy the `grub-with-dtb` part.
  The Dragon Q6A's SPI-NOR EDK2 publishes the board DTB via the EFI
  configuration table and that is the DTB the OS must use; GRUB's
  `devicetree` would replace it wholesale and drop its runtime fixups. The
  hardware-proven Yocto image (`radxa-q6a-yocto`) installs no device tree
  at all - `grep devicetree` over its whole board layer returns nothing.
  Dropping the command also removes the Secure-Boot-must-be-off constraint,
  since that restriction only ever applied to `devicetree`.
  See `PORTING-FROM-YOCTO.md` §2 and B1.
- **Console:** board DTS `stdout-path = "serial0:115200n8"`, `serial0 =
  &uart5` (GENI SE UART → `ttyMSM0`).
- **FastRPC memory model:** mainline sc7280 uses the **dma_heap + SMMU**
  model (fastrpc node has `qcom,fastrpc-compute-cb` context banks,
  `dma-coherent`, `qcom,non-secure-domain`; no `shared-dma-pool`
  carveout). The downstream "no reserved DMA memory for FASTRPC"
  error-14001 does not apply the same way - the fix here is ample global
  CMA (`CONFIG_CMA_SIZE_MBYTES=512`) feeding the CMA dma_heap. remoteproc
  nodes are enabled by the board DTS (`status="okay"`, firmware
  `qcom/qcs6490/cdsp.mbn`).
- **DSP_LIBRARY_PATH:** `/usr/lib/dsp` (shells + skels installed flat).
  fastrpc shell suffixes: `_0`=ADSP, `_3`=CDSP.
- **fastrpc build:** `./autogen.sh` (autoreconf) → `./configure
  --host=aarch64-...` → `make`. Debian `.install` files show libs go to
  `/usr/lib`, `fastrpc_test` to `/usr/bin` + data under
  `/usr/lib/fastrpc_test` and `/usr/share`.

## Worklog

- 2026-07-02: Repo started. Template study done; research agents dispatched
  (kernel/DTB pin, NPU stack, boot chain). Skeleton written. Frozen tuple
  resolved from the agents' downloaded artifacts (they were cut short by a
  session limit but left the DTS, hexagon tree, and fastrpc source on disk).
- 2026-07-03: First full build. Fixed Buildroot arch check rejecting the
  Hexagon DSP6 blobs (`BIN_ARCH_EXCLUDE`). Example app needed
  `Application.start(:nerves_bootstrap)` in config + `rel/vm.args.eex` + a
  clean `_build` (a pre-bootstrap attempt had cached a host-arch NIF).
  Hardened QEMU harness (64 MiB pflash padding, writable EDK2 copy,
  `-cpu max`). **QEMU smoke test PASSED** - IEx console up. app-data p4
  auto-formats + mounts r/w. Remaining: strip fastrpc's systemd/acl udev
  rule (cosmetic log noise); `/dev/watchdog0` absent under QEMU only (HW
  has QCOM_WDT).
