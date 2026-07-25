# Working notes — porting to parity with the proven Yocto system

## Task

Bring this Buildroot/Nerves system to parity with `../radxa-q6a-yocto` (Yocto, **proven on real
Dragon Q6A hardware**: display, WiFi, GPU, NPU, A/B updates). Deliverables written:

- `PORTING-FROM-YOCTO.md` — curated analysis, 7 blockers, 13 major gaps, ordered work plan.
- `PORTING-FINDINGS.md` — all 106 raw findings (8 domains, adversarially verified).

Work is tracked as tasks #1–#22, mirroring the plan's phases.

## Status

**Phase 1 (no hardware) code complete.** Tasks #2–#6 done:

| # | Change | Verification |
|---|---|---|
| 2 | B1 — removed GRUB `devicetree`; use the firmware DTB. DTB → `/usr/share/dtb/` as bench reference. Corrected the wrong "UEFI gives no usable DTB" claim in `grub.cfg`, `fwup.conf`, `fwup-ops.conf`, `README.md`, `GOAL.md` | `grep`: no `devicetree` on any boot path; `fdt` kept in GRUB module list (the `linux` command needs it regardless) |
| 3 | M5 — `net.ifnames=0` on both cmdlines | present in `grub.cfg` + `test/grub.cfg.qemu` |
| 4 | M1 — ESP 32 MiB FAT16 → **256 MiB FAT32** | measured with fwup 1.15.1: 32 MiB→FAT16, 48/128/256 MiB→FAT32 |
| 5 | M2 — upgrades require `nerves_fw_validated=1`; added `upgrade.unvalidated.a/.b` | functionally tested: install → upgrade OK → upgrade **refused** rc=1 → validate → upgrade OK rc=0 |
| 6 | B5 — `autovalidate=0`; StartupGuard + `HEART_INIT_TIMEOUT 900` | option + wiring read from vendored `nerves_runtime` |

Both `fwup.conf` and `fwup-ops.conf` compile (`rc=0`); `post-build.sh` and `qcom-coldplug.sh`
pass `sh -n`.

**UNBLOCKED — host was rebooted `jul 25 ~19:21`.** Deadlock cleared: no build processes left in
`D`, both Docker containers came back healthy, `dmesg` reports zero oops. Phase 1 build (task #7)
restarted via `nix-shell --run "mix compile"`.

The blocker below is kept for the record — if the host wedges the same way again, this is the
signature to match, and the ruled-out dead ends are worth not re-investigating.

Root cause was a **kernel bug, not the build**: `amdgpu_hmm_invalidate_gfx+0x38` NULL pointer
dereference on kernel 6.18.38 (NixOS).

- Oops #1 — `jul 25 14:57:53`, `Comm: kcompactd0`. **This is the fatal one:** the kernel
  memory-compaction daemon died inside the amdgpu MMU-notifier callback, leaking MM locks.
- Oops #2 — `jul 25 18:46:10`, `Comm: brave`, same RIP via
  `try_to_migrate → rmap_walk_anon → __mmu_notifier_invalidate_range_start`.

Since 14:57 anything needing page migration/compaction blocks forever in `D` and cannot be
signalled: `btrfs-transaction`, several `btrfs-endio-write` kworkers, the build's `xzcat`
(stuck on a 280 KB file), horde's `python`, and both Docker containers. Load 152 with ~79% idle
CPU and 11 GiB free RAM is the tell — it is lock leakage, not resource exhaustion.
`docker kill` fails with "did not receive an exit event" on both containers. **Only a reboot
clears this.**

Dead ends ruled out along the way, so they are not re-investigated: disk space (4.1 T free),
btrfs device errors (0 on both devices), a failing disk, btrfs balance (finished cleanly 15:56),
and memory/zram exhaustion (zram was 100% full and horde held 5 GiB of it, but freeing it is
neither possible nor sufficient — horde is a victim of the same deadlock, not the cause).

After reboot: re-run `nix-shell --run "mix compile"`. Buildroot is incremental and its state
lives in the Nerves Docker volume, so it should resume; if `ca-certificates` is left
half-extracted, delete its build dir and let it re-extract.

Aside worth knowing: the kernel is tainted `[S]=CPU_OUT_OF_SPEC` (EXPO/PBO on the B650) with
both `nvidia` and `amdgpu` loaded. The amdgpu HMM NULL deref looks like a genuine 6.18.38 bug,
but if it recurs, the out-of-spec taint is the first thing to rule out.

## Next action

1. **Task #7 DONE** — build finished `jul 25 ~19:52`. **`qemu-smoke.sh` PASSED 5/5** (GRUB slot A →
   kernel → userspace/erlinit → IEx → app banner; IEx at ~18 s) and **`qemu-rollback.sh` PASSED
   11/11** (`SCRIPT EXIT=0`) after the test fix below.
   Sub-checks:
   - **PASS** — LBA 2048 of `test/work/disk.img` reads `NO NAME    FAT32` (M1 confirmed).
   - **UNSATISFIABLE, premise was wrong** — see the ACPI gotcha below. Not a failure; it moves to
     task #1 (needs the board).
   - **PASS (by cmdline, not by NIC name)** — `net.ifnames=0` is on the effective cmdline:
     `Kernel command line: … rootfstype=squashfs rootwait ro net.ifnames=0`. The NIC name itself
     never reaches the serial log (a `virtio-net-device` *is* attached, `qemu-smoke.sh:155`, but
     nothing brings it up before QEMU is killed at the IEx prompt), so the flag reaching the
     kernel is the strongest evidence available post-mortem.
   - Non-issue, do not chase: `nerves_heart: can't open '/dev/watchdog0'` in QEMU. Both
     `CONFIG_WATCHDOG=y` and `CONFIG_QCOM_WDT=y` are set
     (`linux-dragon-q6a.fragment:136,38`) — `-M virt` simply has no Qualcomm WDT.
2. **Task #23 — batch it into Phase 2's first build, do NOT do it alone.** The edit is trivial (the
   `Dockerfile` fwup pin 1.13.1 and `require-fwup-version="1.12.0"` are both below the 1.14.0
   floor) but `Dockerfile` and `fwup.conf` are both in `package_files()` (`mix.exs`), so touching
   them invalidates the artifact checksum and forces a full ~30 min rebuild. Phase 2 edits
   `linux-dragon-q6a.fragment` + `nerves_defconfig` (also checksum inputs) and will invalidate it
   anyway — batching costs one rebuild instead of two.
   Corollary: `test/` is *not* in `package_files()`, so the `qemu-rollback.sh` fix did not
   invalidate the current artifact; it is still the one both gates validated.
3. Then Phase 2 (tasks #8–#11: kernel tree switch, builtin display/GPU, btusb, QTEE), gated by
   task #12 — the merged-`.config` grep, which is the only thing that catches the silent-`=m` trap.
   Phase 2 is where QEMU stops helping: B2 (display/GPU) and B6 (measured boot) both need the board.

## Decisions and gotchas worth not re-deriving

- **`Logger` output never reaches the serial console — never gate a test on a `Logger` line.**
  Nerves routes Logger into an in-memory ring buffer (`config :logger, backends: [RingLogger]`,
  `example/config/target.exs:9`, `config.exs:10`); you read it with `RingLogger.next()` in IEx.
  Only kernel messages, erlinit/fwup output and the app's own `IO.puts` land on serial. I briefly
  gated `qemu-rollback.sh` Phase 1 on StartupGuard's `"Firmware validated successfully"` — it can
  only ever time out. On-disk state (grubenv + uboot-env) is the authoritative evidence.
- **`qemu-rollback.sh` Phase 1 needed a 30 s grace, not a stop-regex change.** StartupGuard's
  `@retry_delay` is 10 s, so on a fresh slot it validates ~10 s *after* the IEx prompt. The old
  hardcoded 5 s grace in `boot_qemu` raced it and produced a false `[FAIL]` on the two validation
  checks. `boot_qemu` now takes an optional grace argument; Phase 1 passes `30`. The old check
  label blamed "autovalidate", which task #6/B5 had already removed — that mislabel is what made
  the failure look like a regression.
- **QEMU cannot test firmware-FDT passthrough at all — it boots via ACPI, not DT.** The planned
  check (`dtc -I fs /sys/firmware/devicetree/base` should show the AAVMF *virt* tree) rests on a
  false premise: the prebuilt `edk2-stable202408` AAVMF hands the kernel **ACPI**, not an FDT.
  Evidence in `test/work/serial.log`: a full ACPI table set (`RSDP/XSDT/FACP/DSDT/APIC/PPTT`),
  `psci: probing for conduit method from ACPI`, `DMI: QEMU QEMU Virtual Machine`, and **zero**
  matches for `Machine model|Unflattening|OF: fdt`. So `/sys/firmware/devicetree/` is empty in the
  guest and the check can never pass.
  What the green smoke test *does* prove about B1 is narrower but still worth having: removing the
  `devicetree` command **does not break booting** when the firmware supplies no FDT. It does
  **not** prove the Dragon Q6A's EDK2 publishes a usable DTB, nor that GRUB forwards it — that
  rests on the hardware knowledge that SPI-NOR EDK2 supplies the DTB plus the proven Yocto system
  shipping zero `devicetree` lines. **Confirm on the board** (`grep -a "Machine model" ` the boot
  log; expect `Radxa Dragon Q6A`-ish, and a populated `/sys/firmware/devicetree/base/`).
- **The "UEFI signature problem" was never a signature problem.** It was EDK2 `TrEE`/`MeasureBoot`
  failing to hash a 47 MB UKI PE image. Nothing in the proven system is signed.
- **Unresolved top risk (task #1, needs the board):** GRUB's arm64 loader boots the kernel via
  firmware `LoadImage()` (`grub-core/loader/efi/linux.c:211`, no non-x86 fallback), so our ~39 MiB
  `CONFIG_EFI_STUB` kernel takes the same path that killed their UKI. systemd-boot avoids it by
  hand-loading PE sections when Secure Boot is off. QEMU cannot test this — its EDK2 reports
  `Tcg2 - Not Found`. Mitigation if it fails: `CONFIG_EFI_ZBOOT` (~15 MB); note
  `BR2_LINUX_KERNEL_VMLINUZ_EFI` is loongarch-only, so use `..._IMAGE_TARGET_CUSTOM`.
- **ESP sized 256 MiB, not the doc's 128 MiB** — asymmetric trade: growing it later shifts every
  partition, i.e. a re-flash of every deployed board, not an OTA.
- **`HEART_INIT_TIMEOUT 900`, contradicting StartupGuard's moduledoc (600)** — 900 matches
  `startup_guard.ex:91` `@give_up_minutes 15` and `heart.ex:93`. (My original rationale for 900 was
  wrong — the handshake happens *early*, at `startup_guard.ex:111`; the value is still right.)
- **fwup task fallthrough only happens on prefix selection.** `-t upgrade` falls through to
  `upgrade.unvalidated.*`; `-t upgrade.a` just reports `Couldn't find applicable task`.
- **Do not edit anything in `package_files()` (`mix.exs`) while a build is running** — those are the
  artifact-checksum inputs (`Dockerfile`, `fwup.conf`, `grub.cfg`, `nerves_defconfig`,
  `linux-dragon-q6a.fragment`, `rootfs_overlay`, `README.md`, `CHANGELOG.md`, …). Editing mid-build
  shifts the checksum out from under the run. `PORTING-*.md` and `WORKING_NOTES.md` are outside the
  list and safe.
- **fwup >2 GB u-boot env bug (task #23): we are not affected, and the version attribution is wrong
  in the Yocto commit.** The fix is fwup **v1.14.0** ("U-Boot environment blocks can now be written
  to offsets beyond 2 GB"), threshold **2 GB**, not 1.16.0/4 GiB — radxa-q6a-yocto `30a00aa` jumped
  1.13.2→1.16.0 and credited the endpoint. Our env is at LBA 64 (32 KiB), first on disk, so it can
  never hit it; theirs is p4 after ~6.5 GiB. Buildroot 2026.05 already ships fwup 1.16.0, so
  host-fwup and the on-target binary are fine. Outstanding: `Dockerfile` debug pin 1.13.1 and
  `require-fwup-version="1.12.0"` are both below the floor — queued as task #23.
- Our **app partition offset is 4.25 GiB** (was ~4.03 GiB even before the ESP change), so large
  offsets do exist in our layout — just not for the env block. Keep the env block at the start.
- v0.1.0 CHANGELOG entry deliberately left as-is (historical record); new behaviour went to
  `Unreleased`.
- The `fable5` risk-guard false-positives on the shell command `truncate` (reads it as SQL
  TRUNCATE). Use `dd ... seek=` to make sparse files.
