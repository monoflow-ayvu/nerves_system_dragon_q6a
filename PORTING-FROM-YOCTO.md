# Porting the proven Radxa Dragon Q6A Yocto config to our Buildroot system

Comparison of this repository (`nerves_system_dragon_q6a`, Buildroot/Nerves — **QEMU-boot proven only**) against
`radxa-q6a-yocto` (Yocto/OpenEmbedded — **proven on real hardware**: display, kernel, WiFi, GPU, NPU, A/B updates).

Citations are prefixed by tree: `ours:path:line`, `yocto:path:line`.

Each finding carries a verdict:

- **CONFIRMED** — an independent adversarial verifier re-read both trees and upheld the claim.
- **corrected** — the verifier amended it; the amended version is what appears here.
- **unverified** — single reading; confirm before acting.

*Method: eight parallel domain investigations across both trees, then every blocker/major claim re-checked by a
separate agent instructed to refute it. 106 findings; 41 were corrected on verification and 11 confirmed outright.*

---

## 1. Executive summary

### The board will not work as-is

Ranked by consequence:

1. **We destroy the firmware-provided device tree.** The SPI-NOR EDK2 compiles the board DTS and hands the OS a DTB
   through the EFI Configuration Table, carrying runtime fixups a statically built DTB cannot have — the memory map
   and reserved-memory carveouts that must agree with what XBL/TZ already established. `ours:grub.cfg:83,88` calls
   `devicetree`, which *replaces* rather than merges. A mismatch does not fail cleanly; it surfaces as SMMU faults or
   ADSP/CDSP remoteproc load failures. The proven system installs no devicetree at all — `grep` for `devicetree` or
   `.dtb` across the entire `meta-q6a-nerveshub` layer returns **zero hits**. → **B1**

2. **The GPU and display cannot probe.** `SC_GPUCC_7280`/`SC_DISPCC_7280` are `=m` for us; the proven config requires
   `=y`. With `CONFIG_ARM_SMMU=y` (builtin, `ours:linux-dragon-q6a.fragment:44`) the adreno SMMU probes at initcall
   time and finds no gpucc clocks → `-110`, and every later adreno bind fails `-19`. Worse for us than for Yocto: our
   modules only load when `qcom-coldplug.sh` starts udevd, *after* the whole BEAM boot, long past
   `deferred_probe_timeout`. → **B2**

3. **Measured boot is an unresolved risk for GRUB** — and it is the item most likely to leave you with a black board.
   See §2; this is not the signature problem you remember. → **B6**

4. **Our kernel tree is not the proven one.** We pin a 31-commit mainline fork; the proven system uses
   `radxa/kernel` branch `linux-6.18.2` @ `559f4f92`, which carries ~70 board commits including DP/HDMI clock-ordering
   fixes and missing GCC GDSC flags. → **B7**

5. **Firmware-validation ordering defeats our own A/B rollback.** We validate before the BEAM starts, so a
   crash-looping release is marked good and never rolled back. The proven system validates only after the application
   is confirmed up. → **B5**

6. **Concrete firmware defects:** the audio topology blob is absent entirely (**B3**); `venus.mbn` points at the wrong
   Venus blob (**M3**); a flat `/usr/lib/dsp` install overwrites four CDSP skels with mismatched ADSP copies (**M4**).

7. **Bluetooth is claimed by the wrong driver** — `CONFIG_BT_HCIBTUSB=m` lets stock `btusb` bind the AIC8800 BT
   interface. → **B4**

8. **Our ESP is FAT16.** UEFI 2.x §13.3.1 mandates FAT32 on fixed media; FAT12/16 is only required for removable.
   QEMU's EDK2 FatPkg mounts FAT16 happily, which is exactly why our tests never caught it. → **M1**

9. **A single bad deployment can brick a unit** — our upgrade tasks accept an upgrade on top of an unvalidated slot;
   the proven ones refuse. → **M2**

10. **No remote access at all.** No sshd, and under `BR2_INIT_NONE` nothing would start one. → **M9**

### Where our design is already equal or better — do not "fix" these

| Area | Why ours stands |
|---|---|
| Kernel inside the slot | Kernel + rootfs upgrade atomically. Theirs keeps per-slot kernels on the shared FAT ESP — strictly more fragile. |
| `/usr/lib/dsp` search path | Sits on fastrpc's compiled-in default search path. Yocto's `qairt-sdk-hexagon-v68` installs skels to an RB3gen2 path **this board never searches**. |
| Ethernet, USB/PCIe, QMP PHY | Builtin for us, modular there — a deliberate superset. |
| No compositor | weston/wayland assumes systemd (`weston.service`, `systemd-notify.so`, logind seats). Direct GBM/KMS + EGL/GLES2 from the app is the correct Nerves design. Yocto's weston-off is *debug scaffolding*, not architecture. |
| Runtime device-path discovery | Ours delegates to erlinit; theirs is defensive shell. No change needed. |

Several things in the reference are **dead code or accidentally-consistent bugs** — `realtek-eth-8169.cfg`, the AIC
firmware install path, `meta-audioreach` (a configured layer contributing nothing to the shipped image). §5 lists them
so nobody ports one.

---

## 2. The boot chain — read this first

```
SPI NOR (Radxa-managed)          OS disk (we build)
PBL → XBL → UEFI/EDK2 ──────────→ ESP ─→ bootloader ─→ kernel + rootfs
         └─ publishes board DTB via EFI Configuration Table
```

SPI-NOR contents (XBL, UEFI, TZ, HYP, DEVCFG, AOP, CDT) are **not** managed by either build system. The machine conf
blanks every Qualcomm boot-firmware variable (`yocto:meta-qcom-3rdparty/conf/machine/radxa-dragon-q6a.conf:26-40`) so
the `qcomflash` class is a no-op. Both projects produce only the OS disk.

### The "signature problem" was not a signature problem

Nothing in the proven system is signed. From `yocto` commit `3bb7a7d` and
`yocto:meta-q6a-nerveshub/recipes-kernel/images/esp-qcom-image.bbappend:12-34`:

> Serial capture shows the board's EDK2 TrEE/MeasureBoot fails to measure the 47MB UKI PE image
> (MeasurePeImgAll/HashLogExtendEvent errors) and aborts boot: hang → watchdog reset ~30s, no console, no journal,
> black screen.

That is **measured boot** (TPM/TrEE PE hashing), not Secure Boot signature verification. The fix was to stop feeding
the firmware a large PE image: systemd-boot Type 1 entries loading a raw kernel `Image` + `cpio.gz`.

**Size alone is not the discriminator.** The failing UKI was 50.6 MiB; the raw `Image` the fix ships is 41.1 MiB —
*larger than our 39.2 MiB kernel*. What changed was the **loader path**.

### Why this is a live risk for GRUB — the finding that changes the verdict

GRUB's arm64 EFI Linux loader does **not** load the kernel itself. It calls firmware `LoadImage()`:

```
grub.cfg  linux ...  → grub_linux_boot() → grub_arch_efi_linux_boot_image()
                     → grub-core/loader/efi/linux.c:211  b->load_image(...)
                     :215  grub_error (GRUB_ERR_BAD_OS, "cannot load image")
                     :238  b->start_image()
```

The x86 handover path that bypasses this is `#if defined(__i386__)||defined(__x86_64__)` only — **there is no
non-x86 fallback**. Our kernel has `CONFIG_EFI_STUB=y`, so it *is* a PE image, and it goes through the same
`LoadImage()` → MeasureBoot path that aborted on the UKI. systemd-boot avoids this by parsing the PE and jumping to
the stub entry point directly when Secure Boot is off.

So: **GRUB routes our 39 MiB kernel through the exact firmware path that killed their 50 MiB UKI.** GRUB has no
graceful degradation — `LoadImage` fails, you get `cannot load image` or a silent ~30 s watchdog reset. This is
invisible to our QEMU test.

This is confirmed on the systemd side too: in systemd v259 `src/boot/linux.c`, `linux_exec()` only calls
`BS->LoadImage` when Secure Boot is enabled *and* shim is involved; otherwise it hand-loads the PE sections with
`xmalloc_pages`+`memcpy` and jumps to the entry point directly. Secure Boot is off on this board, so their Type 1
entries genuinely never touch firmware `LoadImage`.

**Verdict: keep GRUB for now, but treat it as unproven and test it first on the bench.** Switching is *not* a config
flip, and it is more expensive than it looks:

- `BR2_PACKAGE_SYSTEMD_BOOT` is `depends on BR2_i386 || BR2_x86_64` and selects `BR2_PACKAGE_SYSTEMD_EFI` + gnu-efi.
  On aarch64 it needs a genuinely new Buildroot package building only systemd's `src/boot`, under `BR2_INIT_NONE`.
- Their ESP is 512 MiB because it holds two kernels + two initramfs. Ours is 32 MiB and **cannot** hold two ~39 MiB
  kernels; that path needs ~192–256 MiB and a partition-layout change, which is a **re-flash, not an in-place OTA**.
  Size the ESP with this in mind when doing M1.

Do that only if the bench test fails.

> Why QEMU cannot pre-empt this: QEMU's EDK2 has no TPM at all — `ours:test/qemu-run.trimmed.log:27,29` shows
> `Tpm2SubmitCommand - Tcg2 - Not Found`, so measured boot never runs there.

**Honest caveat:** the exact trigger inside the board's EDK2 is unknown. Their raw `Image` is *larger* than ours and
boots fine under systemd-boot, so the fault may be ukify's PE section layout (`.linux`/`.initrd`/`.dtb`) rather than
raw size — in which case GRUB's `LoadImage` of a plain arm64 `Image` would be fine. That is precisely why B6 is a
measurement, not a rewrite.

**Cheap mitigation if it does fail — EFI zboot.** Add to `ours:linux-dragon-q6a.fragment`:

```
CONFIG_EFI_ZBOOT=y
CONFIG_EFI_ZBOOT_COMPRESS_GZIP=y
```

and build `arch/arm64/boot/vmlinuz.efi` (~15 MB; the Yocto tree's `Image.gz` for the same kernel is 15,359,901 bytes)
— a ~2.6× smaller measured payload from a one-line config change. Note `BR2_LINUX_KERNEL_VMLINUZ_EFI` is
`depends on BR2_loongarch64` and **cannot** be used on aarch64; use
`BR2_LINUX_KERNEL_IMAGE_TARGET_CUSTOM=y` + `BR2_LINUX_KERNEL_IMAGE_TARGET_NAME="vmlinuz.efi"` and update
`ours:grub.cfg:84,89` and `ours:post-build.sh`.

### Where the DTB comes from

The EDK2 publishes the board DTB via `EFI_DEVICE_TREE_GUID` (`b1b621d5-f19c-41a5-830b-d9152c69aae0`). On arm64 GRUB
passes that firmware FDT through automatically **when no `devicetree` command is issued** (GRUB 2.02+ through 2.14;
the historical systab bug was 32-bit-arm only). `devicetree` replaces it wholesale and is additionally refused under
Secure Boot. QEMU's AAVMF installs an FDT under the same GUID via `FdtClientDxe`, so passthrough works there too —
and is *more* correct, since QEMU then supplies the `virt` DTB instead of us force-feeding a QCS6490 DTB to a virt
machine.

> Sourced from the GRUB 2.14 manual, Ubuntu bug #1851897, Debian #922101 and the kernel EFI-stub docs — not from
> quoted GRUB source (raw source fetch was blocked). The bench test settles it.

One consequence worth knowing: the EDK2 DTB contains a `simple-framebuffer` node that our in-tree DTB does **not**.
That node is what `simpledrm` binds to, so using the firmware DTB is also a prerequisite for early on-screen output.

### The ESP the proven system actually ships

`yocto:meta-q6a-nerveshub/recipes-kernel/images/esp-qcom-image/`:

```
/EFI/Linux/q6a-a.Image        raw kernel, slot A
/EFI/Linux/q6a-a.cpio.gz      initramfs, slot A
/loader/loader.conf           default q6a-a.conf, timeout 3, editor no
/loader/entries/q6a-a.conf    title/linux/initrd/options — no devicetree line
/loader/entries/q6a-b.conf    same, rootfs-b
```

Options line: `root=PARTLABEL=rootfs-a rw rootwait console=ttyMSM0,115200n8 earlycon console=tty1 net.ifnames=0`.

The machine conf's `WKS_FILE = "efi-uki-bootdisk.wks.in"` (UKI layout) is **dead** — `q6a-nerveshub-image.bb`
overrides it with `q6a-ab.wks.in`, and the bbappend deletes the class-built UKI (`rm -f .../EFI/Linux/q6a.efi`).
`linux-qcom-dtbbin.bbclass` still builds a `dtb-*.vfat`, but no partition flashes it.

---

## 3. Blockers

### B1 — Stop overriding the firmware DTB  *(CONFIRMED)*

**Proven:** `yocto:.../esp-qcom-image/q6a-a.conf:1-4` has four directives — `title`, `linux`, `initrd`, `options`.
No `devicetree`. Zero `devicetree`/`.dtb` hits across the whole layer.

**Ours:** `ours:grub.cfg:16-17` asserts the opposite ("The Qualcomm UEFI does not hand the OS a usable device tree");
`:77` sets `nerves_dtb`; `:83,88` call `devicetree`. `ours:post-build.sh:50-53` installs it into `/boot`.
`ours:nerves_defconfig:42-43` builds it. `fdt` **is** in `BR2_TARGET_GRUB2_BUILTIN_MODULES_EFI`
(`ours:nerves_defconfig:58`), so the command really executes rather than erroring out.

Notably, `ours:test/grub.cfg.qemu:5-8` **already implements the correct behaviour** — so the `devicetree` line in the
hardware `grub.cfg` has never been executed anywhere, including in the only boot we ever proved.

**Fix:**

1. `ours:grub.cfg` — delete `:77` and both `devicetree` lines (`:83`, `:88`). Rewrite the comment block `:11-24`.
2. `ours:post-build.sh:49-54` — keep the install but move it off the boot path, so the bench diff against
   `/sys/firmware/devicetree/base` stays possible:
   ```sh
   install -d $TARGET_DIR/usr/share/dtb
   install -m 0644 $BINARIES_DIR/qcs6490-radxa-dragon-q6a.dtb $TARGET_DIR/usr/share/dtb/
   ```
3. Keep `BR2_LINUX_KERNEL_DTS_SUPPORT=y`, `BR2_LINUX_KERNEL_INTREE_DTS_NAME`, and `fdt` in the GRUB module list —
   `grub-core/loader/efi/linux.c` calls `grub_fdt_load()`/`grub_fdt_install()` unconditionally, so `linux` needs it
   regardless.
4. **Fix the docs that encode the wrong model, or it will be reintroduced:** `ours:fwup.conf:6-9,51,65`,
   `ours:fwup-ops.conf:65`, `ours:README.md:41-46,53,59,166`, `ours:GOAL.md:35-37,77-78,106-110`,
   `ours:CHANGELOG.md:113`. `GOAL.md` currently cites Armbian's `grub-with-dtb` as *validating* the devicetree call —
   replace with the meta-qcom evidence.

**Optional debug hatch.** Rather than deleting outright, gate it so a bench operator can recover a no-FDT board with
`grub-editenv` instead of re-flashing the ESP (`test` is already a builtin module):

```
if [ "$force_dtb" = "1" ]; then devicetree ($nerves_disk,gpt2)$nerves_dtb; fi
```

### B2 — Make the display/GPU stack builtin  *(CONFIRMED)*

**Proven:** `yocto:meta-q6a-nerveshub/recipes-kernel/linux/configs/q6a-display.cfg` (20 lines). Commit `c1ecf57`:

> SC_GPUCC_7280=m meant the adreno SMMU had no clocks/power at its early probe (fail -110), dooming every later
> adreno bind (-19).

The DT mechanism: `sc7280.dtsi`'s `adreno_smmu` takes five `&gpucc` clocks plus `GPU_CC_CX_GDSC`. The Radxa vendor
`qcom_module_defconfig` agrees (`SC_DISPCC_7280=y`, `SC_GPUCC_7280=y`).

**Ours:** `ours:linux-dragon-q6a.fragment:219-223` is a contiguous `=m` block of five symbols. We set **no** DRM base
symbols at all, so `CONFIG_DRM` stays `=m` from the arch defconfig (Deka @`e05c4fa` `defconfig:899`).

**Fix — replace lines 219-223 entirely.** Partial fixes fail: Buildroot merges with `merge_config.sh -m` where the
**last duplicate wins**, and `olddefconfig` silently demotes `DRM_MSM=y` back to `=m` if the helpers stay modular.

```
# --- Display/GPU: builtin, mirroring the proven q6a-display.cfg (c1ecf57)
# --- and the Radxa vendor config-6.18.2-4-qcom.
# --- ARM_SMMU=y (line 44) probes the adreno SMMU at initcall time; it needs
# --- 5 gpucc clocks + GPU_CC_CX_GDSC then. With gpucc=m those arrive only
# --- when qcom-coldplug.sh starts udevd -- after the BEAM boot, long past
# --- deferred_probe_timeout -- so the SMMU latches -ETIMEDOUT, is dropped
# --- from the deferred list and never retried. Every adreno bind then -19.
CONFIG_SC_GPUCC_7280=y
CONFIG_SC_DISPCC_7280=y
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_DISPLAY_HELPER=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
# SYSFB_SIMPLEFB makes sysfb register a "simple-framebuffer" for simpledrm
# instead of an "efi-framebuffer" for efifb. Vendor sets it; our base does not.
# The simple-framebuffer node exists only in the EDK2 DTB -- so this depends
# on B1 landing first.
CONFIG_SYSFB_SIMPLEFB=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_DRM_SIMPLE_BRIDGE=y
CONFIG_DRM_DISPLAY_CONNECTOR=y
CONFIG_DRM_AUX_BRIDGE=y
CONFIG_DRM_MSM=y
CONFIG_DRM_MSM_DP=y
```

Already correct at `ours:linux-dragon-q6a.fragment:31-32` — `QCOM_LLCC=y`, `QCOM_OCMEM=y`. **Do not let these regress
to `=m`:** together with `QCOM_AOSS_QMP=y` (`:33`) and `QCOM_COMMAND_DB=y` (`:16`) they are `depends on X || X=n`
caps in `msm/Kconfig:10-13`, and any one at `=m` silently drops `DRM_MSM` back to `=m`.

`CONFIG_PHY_QCOM_QMP_COMBO=y` (`:165`) only becomes real once `CONFIG_DRM=y` — this is the general trap: **a `=y` in
a fragment silently resolves to `=m` when a tristate dependency is modular.** Always verify the merged `.config`.

Verify after building:
```sh
grep -E 'CONFIG_(DRM|DRM_MSM|SC_GPUCC_7280|SC_DISPCC_7280|DRM_SIMPLEDRM)=' output/build/linux-*/.config
```

### B3 — Ship the audio topology blob  *(CONFIRMED)*

**Ours:** absent. `ours:blobs/qcom-dsp-firmware/lib/firmware/qcom/qcs6490/radxa/dragon-q6a/` has only `adsp.mbn`,
`adspr.jsn`, `adspua.jsn`, `cdsp.mbn`, `cdspr.jsn`.

**Why:** without it the audioreach ASoC card (`q6apm`) fails topology load and **no PCM devices are created** — no
WCD9380 headset path, no DisplayPort/HDMI audio DAI link.

**Fix:**
```sh
cd blobs/qcom-dsp-firmware
BASE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main
curl -fL -o lib/firmware/qcom/qcs6490/radxa/dragon-q6a/QCS6490-Radxa-Dragon-Q6A-tplg.bin \
  $BASE/qcom/qcs6490/radxa/dragon-q6a/QCS6490-Radxa-Dragon-Q6A-tplg.bin
ln -sf radxa/dragon-q6a/QCS6490-Radxa-Dragon-Q6A-tplg.bin \
  lib/firmware/qcom/qcs6490/QCS6490-Radxa-Dragon-Q6A-tplg.bin
(cd lib/firmware && find . -type f -exec sha256sum {} \;) > SHA256SUMS
```
Run the re-hash from the directory containing `lib/firmware`, and keep `-type f` only — the existing `SHA256SUMS`
deliberately omits symlinks.

### B4 — Stop stock `btusb` claiming the AIC8800 Bluetooth interface  *(CONFIRMED)*

**Ours:** the fragment comment says "Do NOT enable BT_HCIBTUSB" but nothing enforces it. We build with
`BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` (`ours:nerves_defconfig:40`) and the arm64 defconfig has
`CONFIG_BT_HCIBTUSB=m` at line 192. `aic_btusb`'s id table competes with stock `btusb`, which matches the generic
Bluetooth interface class — the AIC8800D80 BT interface (`A69C:8D81`, class `e0/01/01`) matches **both**. Whichever
udev modprobes first wins.

**Fix —** append after `ours:linux-dragon-q6a.fragment:184`:
```
# CONFIG_BT_HCIBTUSB is not set
CONFIG_BT_LE=y
```
(`CONFIG_BT_LE` is genuinely needed: the arm64 defconfig explicitly overrides its `default y` with
`# CONFIG_BT_LE is not set` at line 189.)

Belt-and-braces — new file `ours:rootfs_overlay/etc/modprobe.d/aic8800.conf`:
```
blacklist btusb
```
Honoured because eudev's kmod builtin applies `modprobe.d` blacklists to modalias auto-load, which is how modules get
loaded from `qcom-coldplug.sh`.

### B5 — Validate firmware only after the application is up  *(corrected)*

**Proven:** `yocto:.../q6a-boot-select:71-87` polls `systemctl is-active nerves_hub_agent.service` up to 72× at 5 s
(6 min). If the agent never becomes active it exits **without** validating, so the next boot reverts. Only then does
it `sleep 30` and `fw_setenv nerves_fw_validated 1`. The window was widened from 2 to 6 minutes during bring-up —
real-hardware boot timing is slower than you expect.

**Ours:** `ours:fwup.conf:191` arms `nerves_fw_autovalidate=1`; `ours:rootfs_overlay/usr/sbin/qcom-coldplug.sh:21-25`
runs `fwup -q -t reconcile` then `fwup -q -t autovalidate` — **before** erlinit starts the BEAM. Grep finds
`validate_firmware` only in comments; `ours:example/lib/example/application.ex:12` is literally `children = []`.

Our validation bar is "the kernel booted and erlinit ran". A release that crash-loops is marked good and GRUB boots
it forever — the classic unrecoverable OTA.

**Fix:**

1. `ours:fwup.conf:191` → `uboot_setenv(uboot-env, "nerves_fw_autovalidate", "0")`; update the comment at `:185-189`
   and `ours:README.md:76-79`. Keep `autovalidate.a/.b/.skip` in `fwup-ops.conf` as an opt-in for headless images.
2. **Do not** delete the `autovalidate` call from `qcom-coldplug.sh:24` — it is already a no-op when the var is `0`.
   Leave `reconcile` at `:23` untouched; it must precede the app.
3. **Do not** hand-roll a waiter. Use the module `nerves_runtime` already ships:
   ```elixir
   # example/config/target.exs
   config :nerves_runtime, startup_guard_enabled: true
   ```
   ```
   # example/rel/vm.args.eex  (alongside the existing -heart flags)
   -env HEART_INIT_TIMEOUT 900
   ```
   `StartupGuard` issues a `nerves_heart` `init_handshake` (requires `nerves_heart ~> 2.0`; we have v2.5.0). Without
   `HEART_INIT_TIMEOUT` the handshake has no window. Use **900**, not the doc's 600 — it must exceed StartupGuard's
   own 15-minute give-up, or heart reboots before the timer fires. No Buildroot change needed;
   `BR2_PACKAGE_NERVES_HEART` is already selected transitively by `BR2_PACKAGE_NERVES_CONFIG`
   (`ours:nerves_defconfig:76`).

### B6 — Prove the GRUB `LoadImage` path on the bench before anything else

See §2 for the mechanism. **This is the highest-risk item in the port and QEMU cannot test it.**

**First bench action.** Flash, attach serial (`ttyMSM0`, 115200n8), power on, and watch for one of:

| Serial output | Meaning |
|---|---|
| `Booting slot A...` then kernel banner | GRUB path is fine. Proceed. |
| `Booting slot A...` then `cannot load image` | `LoadImage` rejected the kernel → apply EFI zboot (§2), retest. |
| `Booting slot A...` then silence, reset ~30 s | MeasureBoot abort — same failure as their UKI. zboot, then systemd-boot. |

Record the outcome in `ours:BRINGUP.md` before touching anything else — every later diagnosis depends on knowing
which loader path works.

### B7 — Switch to the proven kernel tree  *(corrected)*

**Proven:** `yocto:kas/radxa-q6a-nerveshub.yml:66-70` pins `linux-qcom` `6.18%`, and
`yocto:meta-q6a-nerveshub/recipes-kernel/linux/linux-qcom_%.bbappend:5-6` *replaces* the meta-qcom source with
`git://github.com/radxa/kernel.git;branch=linux-6.18.2` @ `559f4f92`.

**Ours:** `ours:nerves_defconfig:39` pins `Deka-Embedded-Linux/linux-dragon-q6a` @ `e05c4fa` = v6.18 + exactly 31
commits. `ours:patches/` holds only `.gitkeep`. Nothing in our repo references the Radxa tree.

**Why:** the Radxa tree carries ~70 board commits that are the difference between working and broken, not polish —
`drm/msm: dp: Delay applying clock defaults until PHY is fully enabled`, `clk: qcom: gcc-sc7280: Add missing GDSC
flags`, PCIe GDSC and runtime-PM fixes.

**Fix — `ours:nerves_defconfig:39`:**
```
BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="https://github.com/radxa/kernel/archive/559f4f921a01e5358602153364c618fe2a3e431e.tar.gz"
```
Keep `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` and the fragment list: the two trees'
`arch/arm64/configs/defconfig` are **byte-identical** (44334 bytes, md5 `58efbd609552b5518213f117160a7691`), so our
fragment layers on the same base. `BR2_LINUX_KERNEL_INTREE_DTS_NAME` is valid at that SHA.

**Caveats before you flip it:**

- This swaps the DTS too. Radxa **re-enables ICE** (commit `3d40d3a11`) with matching HWKM-v1 driver support
  (`fc1bab211`), while our current Deka DTS *deletes* `qcom,ice` — do not cherry-pick one without the other.
- We lose four Deka-only changes: doubled shared DMA-buf size, the Deka board DTS, an HDMI-audio `hw_params`
  callback, and a 4K30 fix. If the DMA-buf size matters for your workload, carry it as a patch in `ours:patches/`.
- Update `ours:GOAL.md:31,98`, `ours:README.md:12`, `ours:BRINGUP.md:107`, and the comment at
  `ours:nerves_defconfig:34-38`.

---

## 4. Major gaps

### M1 — ESP must be FAT32, not FAT16  *(corrected)*

Measured on our own image: boot sector at LBA 2048 of `test/work/rollback-disk.img` reports fstype `FAT16`.
`ours:fwup.conf:61-62` and `ours:fwup-ops.conf:61-62` both define `BOOT_PART_COUNT, 65536` (32 MiB), and
`fat_mkfs` at 32 MiB picks FAT16. UEFI 2.x §13.3.1 mandates FAT32 for a fixed-media ESP.

**Fix — in both files. IMPLEMENTED as 256 MiB, not 128:**
```
define(BOOT_PART_COUNT, 524288)  # 256 MiB, FAT32
```
Sized once, generously, because the trade is asymmetric: over-sizing costs unused disk, while under-sizing costs a
re-flash of every deployed board (growing the ESP shifts every partition — it is not an OTA). 256 MiB also leaves
room for the systemd-boot fallback in B6, which needs two kernels on the ESP.

**Threshold measured directly with our own fwup 1.15.1** rather than taken on trust — `fat_mkfs` at each size, then
reading the FS-type string out of the boot sector at LBA 2048:

| ESP size | blocks | BPB field | FS type |
|---|---|---|---|
| 32 MiB | 65536 | offset 54 | `FAT16` |
| 48 MiB | 98304 | offset 82 | `FAT32` |
| 128 MiB | 262144 | offset 82 | `FAT32` |
| **256 MiB** | **524288** | offset 82 | **`FAT32`** |

So the FatFs crossover is just above 32 MiB (cluster count > 65525), and anything ≥ 48 MiB is FAT32.
The FatFs crossover is just **above 32 MiB**, not 64: measured 32 MiB → FAT16; 48/64/96/128/512 MiB → FAT32. Anything
≥ 48 MiB works. Also update the ASCII layout comments at `ours:fwup.conf:49` and `ours:fwup-ops.conf:50`.
`ROOTFS_A_PART_OFFSET` moves 67584 → 264192 via the existing `define-eval`; both tests hardcode only offset 2048 and
are unaffected. Re-dump LBA 2048 afterwards and confirm `FAT32` at offset 82.

The `name = "ESP"` rename sometimes suggested alongside this is **cosmetic only** — nothing in our repo consumes the
GPT partition name.

### M2 — Refuse upgrades onto an unvalidated slot  *(CONFIRMED)*

**Proven:** `yocto:.../radxa-dragon-q6a.fwup:117-122,175-180` — each upgrade task carries **four** requires,
including `require-uboot-variable(uboot-env, "nerves_fw_validated", "1")`.

**Ours:** `ours:fwup.conf:235-239` / `:296-300` never consult `nerves_fw_validated`.

**Fix —** insert after `ours:fwup.conf:235` and after `:296`:
```
require-uboot-variable(uboot-env, "nerves_fw_validated", "1")
```

Add diagnostics **after** `upgrade.b` (`:351`) and **before** `upgrade.unexpected` (`:353`). Gate on the active slot,
not on `nerves_fw_validated == "0"` — `require-uboot-variable` also fails on a *missing* variable, so a wiped KV store
would otherwise fall through to a misleading "neither A nor B is active":

```
task upgrade.unvalidated.a {
    require-uboot-variable(uboot-env, "nerves_fw_active", "a")
    on-init {
        error("Refusing to upgrade: running firmware is not validated (nerves_fw_validated != 1). Validate it (Nerves.Runtime.validate_firmware/0), or reboot to let the GRUB boot-once rollback complete.")
    }
}
task upgrade.unvalidated.b {
    require-uboot-variable(uboot-env, "nerves_fw_active", "b")
    on-init {
        error("Refusing to upgrade: running firmware is not validated (nerves_fw_validated != 1). Validate it, or reboot to let the GRUB boot-once rollback complete.")
    }
}
```

### M3 — Wrong Venus firmware blob  *(CONFIRMED)*

`ours:blobs/.../qcom/vpu-2.0/venus.mbn` symlinks `../vpu/vpu20_p4.mbn`, i.e. a **VPU-1.0** image handed to a VPU-2.0
block. PAS/TZ authentication fails and `CONFIG_VIDEO_QCOM_VENUS=m` never produces `/dev/video*`.

```sh
cd blobs/qcom-dsp-firmware/lib/firmware
curl -fL -o qcom/vpu/vpu20_p1.mbn \
  https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/qcom/vpu/vpu20_p1.mbn
ln -sfn ../vpu/vpu20_p1.mbn qcom/vpu-2.0/venus.mbn
```
Keep `vpu20_p4.mbn` only if you also add `qcom/vpu-1.0/venus.mbn -> ../vpu/vpu20_p4.mbn` (mirrors upstream);
otherwise drop it to save 1.9 MB per slot. Regenerate `SHA256SUMS` and fix the layout table in the blob README.

### M4 — Per-domain DSP skel install  *(CONFIRMED)*

`ours:package/qcom-dsp-shell/qcom-dsp-shell.mk` copies the CDSP dir and then the ADSP dir into **one flat**
`/usr/lib/dsp/`. They share filenames, so four CDSP skels are silently overwritten by mismatched ADSP-version copies.

**Fix:** install per-domain (`/usr/lib/dsp/cdsp/`, `/usr/lib/dsp/adsp/`); keep
`QCOM_DSP_SHELL_BIN_ARCH_EXCLUDE = /usr/lib/dsp` (covers subdirs). Also move the QAIRT HTP skels from
`package/qairt-runtime` into `/usr/lib/dsp/cdsp/` for auditability — they resolve either way via the bare-dir
fallback.

**Do not change `DSP_LIBRARY_PATH`/`ADSP_LIBRARY_PATH`** in `ours:rootfs_overlay/etc/erlinit.config:32` or
`ours:rootfs_overlay/etc/profile.d/qcom-npu-env.sh:3-4`. Verified at our pinned fastrpc commit `706071c`:
`get_dirlist_from_env()` does **not** append the domain, and `fopen_from_dirlist()` appends `SUBSYSTEM_NAME[domain]`
exactly once. Setting `/usr/lib/dsp/cdsp` would produce `/usr/lib/dsp/cdsp/cdsp/`.

### M5 — Add `net.ifnames=0`  *(CONFIRMED)*

eudev's `80-net-name-slot.rules` renames interfaces unless this is on the cmdline. Add to **both**:

- `ours:grub.cfg:75` — append to `nerves_cmdline`
- `ours:test/grub.cfg.qemu:38` — otherwise the QEMU NIC becomes `enp0s1` and the tests silently diverge from hardware

There is no `BR2_*` knob for this, and `BR2_PACKAGE_EUDEV_RULES_GEN=y` is the wrong lever.

### M6 — Bump the AIC8800 driver  *(CONFIRMED)*

`ours:package/aic8800/aic8800.mk:11` pins release `-6`; the hardware-proven one is `-7`, adding
`fix-usb-suspend-reboot-hang.patch` — it removes a `down(&aicwf_deinit_sem)` in `aicwf_usb_rx_complete()` that blocks
on the disconnect callback when a URB errors, i.e. a real reboot/suspend hang.

```
AIC8800_VERSION = 6e076049b719ac2ff7ce5c92786a680407b11cdb
```
The full 25-patch series was verified to apply cleanly at that rev after our CRLF normalization. Note there is no
`.hash` file today, so Buildroot downloads unverified.

### M7 — Retry remoteproc firmware load after the rootfs is up  *(corrected)*

`CONFIG_QCOM_Q6V5_PAS=y` (`ours:linux-dragon-q6a.fragment:71`) probes with `auto_boot` and issues
`request_firmware_nowait()` for `qcom/qcs6490/radxa/dragon-q6a/{adsp,cdsp}.mbn`. As a builtin that work item can run
**before the squashfs root is mounted** — we have no initramfs — so the load fails `-ENOENT` and both remoteprocs sit
`offline`.

**Fix (additive, zero-risk, works whether the chain is `=y` or `=m`)** — in
`ours:rootfs_overlay/usr/sbin/qcom-coldplug.sh`, after the `udevadm settle` block and before the
`chmod 666 /dev/fastrpc-*` block:

```sh
# Built-in qcom_q6v5_pas auto_boot can fire before the squashfs root is
# mounted, so cdsp.mbn/adsp.mbn load with -ENOENT and the remoteprocs sit
# "offline". Retry now that /lib/firmware is available.
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -w "$rp/state" ] || continue
    if [ "$(cat "$rp/state" 2>/dev/null)" = "offline" ]; then
        echo start > "$rp/state" 2>/dev/null || true
    fi
done
```

Also fix the fragment header comment at `:4-7`, whose stated rationale for `=y` is wrong — the `.mbn` files are on the
rootfs either way.

### M8 — Record and check the SPI-NOR firmware floor  *(corrected)*

Boot firmware older than **`6.0.260120.BOOT.MXF.1.0.1-00549-KODIAKWP-1`** makes QTEE reject *unsigned* DSP protection
domains with `0x80000600`. QNN and `fastrpc_test -a v68` both need unsigned PD, so on an un-upgraded board the NPU is
dead no matter how correct everything else is — and it will look like a blob/version mismatch.

`ours:BRINGUP.md:31-32` says only "Armbian notes the latest UEFI firmware is required". The exact string is missing.

**Fix (docs-first; the flash itself is host-side and not a build-system change):**

1. Put the exact version in `ours:BRINGUP.md` §1, `ours:README.md` next to the existing `0x80000600` paragraph
   (`:105-111`), `ours:GOAL.md:103`, and `ours:blobs/qcom-dsp-firmware/README.md:41-42`. Note **0x80000600 has two
   causes** — blob/shell mismatch *or* old SPI firmware — and say to check the firmware first.
2. Warn at boot, in `qcom-coldplug.sh` before the fastrpc daemons start. No new package needed: `CONFIG_DMI` is
   already implied by `CONFIG_EFI=y` on arm64, so `cat /sys/class/dmi/id/bios_version` just works. Wrap in `|| true`
   like the rest of the script so it can never block the app.
3. `BR2_PACKAGE_DMIDECODE=y` is valid on aarch64 but buys nothing over sysfs — skip it. If you do add it, it *also*
   needs `CONFIG_DMI_SYSFS=y` (default n, absent from the arm64 defconfig), since arm64 has no legacy `/dev/mem`
   SMBIOS scan.

### M9 — Add SSH  *(CONFIRMED)*

**Proven:** openssh + root login + `/data`-persisted host keys so slots A and B present **one identity**
(`yocto:.../q6a-nerveshub-image.bb:101-110`).

**Ours:** nothing. Only the IEx console on `ttyMSM0`.

**Fix — application-side only; no defconfig change.** `ours:nerves_defconfig:76` (`BR2_PACKAGE_NERVES_CONFIG=y`)
already selects OpenSSL, so Erlang builds `--with-ssl` and `:ssh` is available. **Do not** add
`BR2_PACKAGE_OPENSSH` or `BR2_PACKAGE_OPENSSL`.

```elixir
# example/mix.exs
{:nerves_ssh, "~> 1.0"}   # 1.3.0; pulls ssh_subsystem_fwup for `mix upload`
```

Override **both** directories. `nerves_ssh` 1.3.0 defaults to `/data/nerves_ssh` and `/data/nerves_ssh/default_user`,
and **we have no `/data`** — our writable app partition mounts at `/root`
(`ours:rootfs_overlay/etc/erlinit.config:41`). Without the override, host keys are regenerated every boot and differ
between slots.

### M10 — Prove `save_env` reaches the media  *(corrected)*

Our whole boot-once scheme depends on GRUB writing `booted_once=1` to `grubenv` on the ESP via EFI Block I/O. If that
write silently fails on real hardware, a trial slot is retried forever and the fallback branch is never reached —
auto-rollback is dead while every test still passes, because the happy path needs no write.

There *is* on-media proof from a real run: `ours:test/work/rollback-serial.log:13` shows the fallback firing, and
`test/work/grubenv.probe` differs from `grubenv.crafted` as expected. But that was QEMU.

**Bench test — isolate `save_env` first, no OTA needed:**

```sh
mount -t vfat -o rw /dev/rootdisk0p1 /mnt
# overwrite /mnt/EFI/BOOT/grubenv with a 1 KiB GRUB env block:
#   "# GRUB Environment Block\n" + boot=0 / booted_once=0 / validated=0
#   + '#' padding to exactly 1024 bytes  (format: test/qemu-rollback.sh:145-155)
umount /mnt && reboot
# after reboot:
mount -t vfat -o ro /dev/rootdisk0p1 /mnt && head -c 200 /mnt/EFI/BOOT/grubenv
```
`booted_once=1` proves the write reached the media through Radxa's EDK2 BlockIo.

Two traps: **disable autovalidate first** (`fw_setenv nerves_fw_autovalidate 0`) or `qcom-coldplug.sh` writes
`validated=1` from Linux and the test proves nothing; and **do not** plan to verify with `grub-editenv` on target —
Buildroot's grub2 is a bootloader package, not a host-tools install.

### M11 — Enable QTEE  *(corrected)*

`yocto:.../configs/q6a-platform.cfg` is three lines whose entire content is `CONFIG_QCOMTEE=y`. We have zero hits
repo-wide.

The common claim that "we build no TEE driver at all" is **false** — the arm64 defconfig at Deka `e05c4fa` has
`CONFIG_TEE=y` (1707) and `CONFIG_OPTEE=y` (1708). But QCS6490 runs QTEE, not OP-TEE, so no `tee0` appears.

```
# --- Qualcomm TEE (QTEE): creates /dev/tee0. Base arm64 defconfig ships
# --- CONFIG_TEE=y + CONFIG_OPTEE=y, but QCS6490 runs QTEE, not OP-TEE.
CONFIG_QCOMTEE=y
```
Verified in our exact kernel: `drivers/tee/qcomtee/Kconfig` is `tristate`, `depends on ARCH_QCOM`, and sits inside
`if TEE` — so it only sticks because `CONFIG_TEE=y` is already set. No devicetree node needed (registered as a
platform device by `qcom_scm_qtee_init()`), which matters given the DTB comes from UEFI.

### M12 — Align the QAIRT pin; decide on an inference runtime  *(corrected)*

The proven board runs QAIRT **2.47.0.260601** skels plus a wheel-based `onnxruntime` 1.28.0 + `onnxruntime_qnn` 2.4.0
stack. `ours:blobs/qairt-runtime/` is SDK **2.42.0.251225**, consumed by an Elixir NIF that exists only as prose in
its README. `ours:GOAL.md`'s frozen tuple has no QAIRT row at all.

**Minimum:** add a QAIRT/QNN row to the frozen tuple naming the SDK version and the five vendored files; either
re-harvest from 2.47.0.260601 or record why 2.42 stays.

**Then verify the SONAME:** `readelf -d` shows `libQnnHtpV68Stub.so` needs unversioned `libcdsprpc.so`, while
`package/qcom-fastrpc` installs SONAME `libcdsprpc.so.1`. Yocto carries a `patchelf --replace-needed` for exactly
this, noting the upstream fix landed in SDK **v2.45** — our 2.42 predates it. Buildroot's libtool install normally
leaves the unversioned symlink, so it probably resolves; confirm with `ldd` on target.

Full ONNX port is a scoped decision, not a defect — see §5.3 q8.

### M13 — Bluetooth is unproven end-to-end on both systems  *(corrected)*

There is **no BT userspace on either image** — no tool on the Yocto board can open an HCI device. So "BT works on the
Yocto board" cannot be true in any tested sense, and we get no proven reference. Treat BT as greenfield: land B4
first, then decide between BlueZ (`BR2_PACKAGE_BLUEZ5_UTILS`, pulls dbus) and a Nerves-native stack.

---

## 5. Minor gaps and informational differences

74 findings landed at minor/informational severity. They fall into three groups; the full ranked list with per-item
actions lives in the appendix table below.

### 5.1 Worth doing — small, low-risk

| # | Area | Change |
|---|---|---|
| m1 | Kernel cmdline | Add `earlycon` and `console=tty1` to match the proven entry — without them a bring-up failure is silent |
| m2 | Kernel cmdline | Drop `clk_ignore_unused pd_ignore_unused`; Yocto removed them once display worked (they mask real clock bugs) |
| m3 | Kernel cmdline | Consider `qcom_scm.download_mode=1` (the kas base adds it) for crash dumps |
| m4 | Firmware | Add the `qcom/qcs6490/qupv3fw.elf` symlink — the DTS uses the `qcm6490` path |
| m5 | Firmware | Drop ~16 MB of generic `qcm6490` adsp/cdsp images the proven system does not install |
| m6 | Firmware | Install linux-firmware license/notice files into `/lib/firmware` |
| m7 | Networking | Ship `rtl_nic` firmware for the RTL8111 — neither system does today |
| m8 | Display | Add `BR2_PACKAGE_GLMARK2=y` + `BR2_PACKAGE_MESA3D_DEMOS=y` (both verified present) — we have **no** way to test GL. Note glmark2 adds ~15-20 MB of assets |
| m9 | Boot | Add ESP FAT repair equivalent — the proven system needed it after hard power cuts, and we write the ESP at runtime *more* often than they do |
| m10 | Diagnostics | Nothing persists across a failed boot; Yocto explicitly added persistent logs |

### 5.2 Deliberate divergences — leave as they are

| Area | Their approach | Why ours stands |
|---|---|---|
| `realtek-eth-8169.cfg` | Present in the layer | **Dead code** in the proven build — ethernet runs as a module there. Ours is a superset. |
| AIC firmware install path | Recipe path is wrong-but-accidentally-consistent | Do not port the bug. |
| `qairt-sdk-hexagon-v68` skels | `/usr/share/qcom/.../RB3gen2/dsp/cdsp` | A path this board never searches. Our `/usr/lib/dsp` is on fastrpc's default search path. |
| `meta-audioreach` | Configured layer | Contributes **nothing** to the shipped image. |
| `tpm2.target`, `qteesupplicant` | Masked units | systemd artifacts; no analogue needed. The lesson — never block boot on a device that may not exist — we already honour via `|| true`. |
| `qrtr`/`rmtfs`/`tqftpserv` | systemd services | Evaluate on need, not for parity. |
| Compositor | weston (autostart disabled anyway) | No clean Nerves analogue; direct GBM/KMS is correct. |

### 5.3 Open questions

| # | Question | How to resolve |
|---|---|---|
| q1 | Does EDK2 `LoadImage()` accept our 39 MiB kernel? | **B6 bench test.** Everything else in §2 is contingent on this. |
| q2 | Does GRUB's `save_env` reach the media on real EDK2? | **M10 bench test.** |
| q3 | Does the firmware DTB actually appear, and does it contain `simple-framebuffer`? | After B1: `dtc -I fs /sys/firmware/devicetree/base` on target; diff against `/usr/share/dtb/`. |
| q4 | Is the board's SPI firmware at or above the floor? | `cat /sys/class/dmi/id/bios_version` |
| q5 | Does `libQnnHtpV68Stub.so` resolve `libcdsprpc.so`? | `ldd /usr/lib/libQnnHtpV68Stub.so` on target |
| q6 | Do our ESP/partition layouts need to interoperate with the Yocto image? | Product decision. The two on-disk layouts are **mutually incompatible** today. |
| q7 | Does the Deka doubled DMA-buf size matter for our workload? | Required before B7; if yes, carry as a patch. |
| q8 | Is ONNX/QNN inference in scope? | If yes: needs **glibc ≥ 2.34** in the Nerves toolchain (`onnxruntime_qnn` is `manylinux_2_34`), and several hundred MB against a 2 GiB slot cap (`ours:fwup.conf:65,111`). Verify the toolchain first. |
| q9 | 4096-byte sector media (UFS)? | Both fwup layouts assume 512-byte logical sectors; the Yocto machine conf at least flags it (`QCOM_VFAT_SECTOR_SIZE`). |

---

## 5.4 Implementation status

Phase 1 (the fixes needing no hardware) is **implemented**; see the `Unreleased` section of `CHANGELOG.md`.

| Item | Status | Evidence |
|---|---|---|
| B1 DTB override removed | done | no `devicetree` on any boot path; `fdt` kept in the GRUB module list |
| M5 `net.ifnames=0` | done | present in both `ours:grub.cfg` and `ours:test/grub.cfg.qemu` |
| M1 ESP → FAT32 @ 256 MiB | done | measured FAT32 with fwup 1.15.1 (table above) |
| M2 refuse unvalidated upgrade | done | functionally tested — see below |
| B5 validate after app start | done | `startup_guard_enabled: true` + `HEART_INIT_TIMEOUT 900` |
| Phase 1 QEMU regression | **pending** | needs a full Buildroot rebuild |

**M2 was verified functionally, not just by inspection.** Against a real disk image with fwup 1.15.1:

1. factory install (`complete`) → `nerves_fw_validated=1`
2. `fwup -t upgrade` → allowed, writes slot B, sets `validated=0` (trial)
3. `fwup -t upgrade` again → **refused**, `rc=1`, with the `upgrade.unvalidated.b` message
4. `fwup -t validate` (ops.fw) → `Validating slot B`, `rc=0`
5. `fwup -t upgrade` → allowed again (`Upgrading partition A`), `rc=0`

Note step 3 only exercises the guard through the `upgrade` **prefix**, which is how Nerves invokes it. An explicit
`-t upgrade.a` reports `Couldn't find applicable task` instead, because fwup does not fall through on exact-name
selection — worth knowing when testing by hand.

B5's `startup_guard_enabled` option and the 900 s heart timeout were confirmed against the vendored dependency, not
assumed: `example/deps/nerves_runtime/lib/nerves_runtime/application.ex:24-25` reads the option,
`.../startup_guard.ex:91` sets `@give_up_minutes 15`, and `.../heart.ex:93` documents `HEART_INIT_TIMEOUT 900`. (The
`StartupGuard` moduledoc suggests 600; 900 is used so the heart window matches the guard's own give-up.)

---

## 6. Ordered work plan

Phases are ordered by dependency. **Do not reorder 0 before 1** — the loader verdict determines whether the rest is
even worth building.

### Phase 0 — Bench the boot path (hardware, before any code change)

1. Flash current image, attach serial, power on. Record which of the three B6 outcomes occurs.
2. `cat /sys/class/dmi/id/bios_version` → record against the M8 floor.

*Verifies:* whether GRUB is viable at all, and whether the NPU can ever work on this board.
**Cannot be done in QEMU.**

### Phase 1 — Correctness fixes that need no hardware

3. **B1** DTB override removal + all doc corrections.
4. **M5** `net.ifnames=0` in both grub configs.
5. **M1** ESP → FAT32.
6. **M2** refuse upgrades onto unvalidated slots.
7. **B5** validation ordering (`autovalidate=0` + StartupGuard).

*Verify:* `test/qemu-smoke.sh` and `test/qemu-rollback.sh` both pass; re-dump LBA 2048 and confirm `FAT32`; confirm
the QEMU boot now uses the AAVMF-supplied virt DTB (`dtc -I fs /sys/firmware/devicetree/base` inside the guest shows
`virt`, not `qcs6490`).

### Phase 2 — Kernel

8. **B7** switch to `radxa/kernel` @ `559f4f92` (resolve q7 first).
9. **B2** builtin display/GPU block.
10. **B4** `# CONFIG_BT_HCIBTUSB is not set` + `CONFIG_BT_LE=y` + modprobe blacklist.
11. **M11** `CONFIG_QCOMTEE=y`.

*Verify (build host):* `grep -E 'CONFIG_(DRM|DRM_MSM|SC_GPUCC_7280|SC_DISPCC_7280|DRM_SIMPLEDRM|QCOMTEE|BT_HCIBTUSB)='
output/build/linux-*/.config` — every one must read `=y` except `BT_HCIBTUSB`, which must be absent or `is not set`.
This catches the silent-`=m` trap and is the single most important check in the whole plan.
*Verify (QEMU):* smoke test still boots.

### Phase 3 — Firmware and drivers

12. **B3** audio topology blob.
13. **M3** Venus blob.
14. **M4** per-domain DSP skel install.
15. **M7** remoteproc retry in `qcom-coldplug.sh`.
16. **M6** AIC8800 bump.
17. **M8** firmware-floor docs + boot warning.

*Verify (QEMU):* smoke test passes; `SHA256SUMS` regenerated and matching.
*Verify (hardware):* `/sys/class/remoteproc/*/state` all `running`; `aplay -l` lists PCM devices;
`fastrpc_test -a v68` passes; `dmesg | grep -i adreno` shows no `-110`/`-19`; `modetest -M msm -c` lists a connector.

### Phase 4 — Operability

18. **M9** `nerves_ssh` with `/root`-based key dirs.
19. **M10** `save_env` bench test.
20. §5.1 items m1–m10 as capacity allows.

*Verify:* `ssh` in from another host across a reboot and confirm the **host key is unchanged**; `mix upload` succeeds.

### What QEMU can never tell you

Measured boot / `LoadImage`, the real DTB handoff, SMMU and remoteproc behaviour, GRUB's `save_env` against real
EDK2 BlockIo, actual A/B media behaviour, and every firmware blob. A green QEMU run is a regression gate, **not**
hardware confidence.

---

## 7. Provenance

Findings were produced by eight parallel domain investigations over both trees, each blocker/major claim then
re-checked by an independent agent instructed to refute it. Of 106 findings: 11 CONFIRMED outright, 41 amended on
verification (the amended text is what appears above), 54 single-source at minor/informational severity.

The GRUB firmware-FDT behaviour in §2 was verified against the GRUB 2.14 manual, Ubuntu bug #1851897, Debian #922101
and the kernel EFI-stub documentation — not against quoted GRUB source, which was unreachable. The
`grub-core/loader/efi/linux.c` line references come from the Buildroot-vendored GRUB 2.12 tree at
`ours:deps/nerves_system_br/buildroot-2026.05/`.
