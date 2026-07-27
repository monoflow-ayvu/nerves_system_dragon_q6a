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

## Phase 2 (in progress)

Committed Phase 1 as `2497e2e` on branch **`phase1-yocto-parity`** (was on `main`; fast-forward
`main` onto it when ready).

| # | Change | State |
|---|---|---|
| 9 | **B2** display/GPU builtin — replaced the `=m` block with `SC_GPUCC_7280`/`SC_DISPCC_7280`/`DRM`/`DRM_MSM`/`DRM_MSM_DP`/simpledrm/`SYSFB_SIMPLEFB` all `=y` | code done, awaiting task #12 gate |
| 10 | **B4** `# CONFIG_BT_HCIBTUSB is not set` + `CONFIG_BT_LE=y` + new `rootfs_overlay/etc/modprobe.d/aic8800.conf` (`blacklist btusb`) | code done |
| 11 | **M11** `CONFIG_QCOMTEE=y` (base defconfig already has `TEE=y`+`OPTEE=y`; QCS6490 runs QTEE so no `tee0` without this) | code done |
| 23 | fwup floor: `Dockerfile` `FWUP_VERSION` 1.13.1→**1.16.0**, `fwup.conf` `require-fwup-version` 1.12.0→**1.14.0**. Both release assets verified to exist (HTTP 200); host fwup 1.15.1 parses past the new floor | code done |
| 8 | **B7** kernel tree switch — **q7 answered: take `radxa/kernel` clean, no DMA-buf patch** | BLOCKED until the running build finishes (`nerves_defconfig` is a `package_files()` input) |

**q7 resolved (user, 2026-07-25):** drop the four Deka-only changes.

**The q7 risk was overstated — corrected after reading the actual commits.** `e05c4fae`
("deka-board double shared dma buf size") modifies only
`arch/arm64/boot/dts/qcom/qcs6490-radxa-dragon-q6a-deka-board.dts` — **Deka's own carrier board**,
not `qcs6490-radxa-dragon-q6a`, which is what we build. It was never active for us, so dropping it
costs nothing; there is no dma-buf-exhaustion risk to accept.

What the Deka fork actually was: v6.18.0 + 31 commits, of which ~27 are a point-in-time snapshot of
*Radxa's own* enablement work (board DTS, `qcom_module_defconfig`, UFS/eMMC, PCIe, dpu catalog,
`remoteproc: core: Allow auto retry of rproc_start()`, plus a self-described **temporary**
`qmp-combo: fix the orientation to reverse` hack). Only the last four commits are Deka's, for their
own board. radxa/kernel is the continuation of the same lineage — 6.18.2 stable base, ~70 board
commits — not a competing tree.

The only Deka patches touching *shared* drivers, i.e. the real candidates if ever needed:
- `52a1da01` "fix 4K 30 fps" → `dpu_7_2_sc7280.h`, `dp_display.c`, `dp_panel.c`
- `3b0e34ee` HDMI-audio `hw_params` → `drm_hdmi_audio_helper.c`
Check whether radxa/kernel already covers these before porting either.

Taking the tree wholesale also resolves the ICE caveat for free — Radxa's `qcom,ice` re-enable
(`3d40d3a11`) and its HWKM-v1 driver support (`fc1bab211`) arrive together, which is what B7 warns
against splitting.

B7 edit, once the build is done (`nerves_defconfig:39`; tarball verified HTTP 200):
```
BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="https://github.com/radxa/kernel/archive/559f4f921a01e5358602153364c618fe2a3e431e.tar.gz"
```
Keep `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` — the two trees' `arch/arm64/configs/defconfig`
are byte-identical per the plan (44334 bytes, md5 `58efbd609552b5518213f117160a7691`); **verify that
before trusting it.** Then update the doc references B7 lists: `GOAL.md:31,98`, `README.md:12`,
`BRINGUP.md:107`, `nerves_defconfig:34-38`.

Deliberately doing two builds rather than one: the in-flight build gates B2/B4/M11 on the *current*
Deka tree, so if a symbol turns out not to exist we learn that independently of the tree swap.

## Phase 3 — re-scope M7 before implementing it

**M7 (retry remoteproc firmware load after the rootfs is up) may be largely solved in-kernel by
the B7 tree switch. Do not write the shell retry loop before checking the board.**

radxa/kernel carries a mechanism mainline does not have. Upstream 6.18 has a plain
`bool auto_boot`; this tree has a tri-state (`include/linux/remoteproc.h:521-525`):
```c
enum rproc_auto_boot {
	RPROC_AUTO_BOOT_DISABLED,
	RPROC_AUTO_BOOT_ATTACH_OR_START,
	RPROC_AUTO_BOOT_RESTART_IF_FW_AVAILABLE,
};
```
`drivers/remoteproc/remoteproc_core.c:1943-1951` — when a remoteproc is `RPROC_DETACHED` (already
running from XBL/TZ) and `auto_boot == RESTART_IF_FW_AVAILABLE`, `rproc_boot()` re-runs
`request_firmware()`; if the firmware is now present it logs
`"restarting %s with new firmware"`, stops the pre-booted instance and restarts it with ours.
`drivers/remoteproc/qcom_q6v5_pas.c:767` is what selects that mode.

That is precisely M7's problem — firmware not yet reachable at probe time — handled with correct
stop/restart semantics. Deka solved the same thing differently, with
`a2cfed4d remoteproc: core: Allow auto retry of rproc_start()`.

So on bench, first check `dmesg | grep -iE "restarting .* with new firmware|remoteproc"` and
`/sys/class/remoteproc/*/state`. A naive shell retry could fight this rather than help. What may
still be needed is only the *trigger* (something calling `rproc_boot` once the rootfs is up), not
the retry logic itself.

## ortex + QNN on the HTP (tasks A–E)

Goal: run ONNX models on the NPU from Elixir via `ortex`.

**The finding that makes this cheap:** `ort`'s QNN EP registers through the generic
`SessionOptionsAppendExecutionProvider(session, "QNN", opts)` (pykeio/ort `src/ep/qnn.rs`), and
`register()` is *not* feature-gated. onnxruntime `dlopen()`s
`libonnxruntime_providers_qnn.so` at session creation, so a **stock** libonnxruntime works and
there is no need to build ONNX Runtime from source against the QAIRT SDK — which matters because
Qualcomm does not officially support the QNN SDK on aarch64 Linux.

| Task | State |
|---|---|
| A. `onnxruntime-qnn` Buildroot package (24 MB) | **DONE**, verified in the artifact |
| B. Rust cross-compile for aarch64 Nerves | **DONE**, `libortex.so` is an aarch64 ELF |
| C. Patch ortex for `:qnn` | **DONE**, compiles |
| D. Test models (fp32 + QDQ int8) | **DONE**, both in `example/priv/` |
| E. ONNX inference on the board | **DONE** — verified live over SSH |
| E. QNN/NPU acceleration | **BLOCKED** — see below |

**ONNX Runtime genuinely works on the board**, verified over SSH on hardware:
```
Example.NPU.run(:cpu)      -> {:ok, [22.0, 44.0, 66.0, 88.0], 1394}     # (a+b)*2
Example.NPU.run_qdq(:cpu)  -> {:ok, [38.0, 40.0, ... 52.0], ...}        # QDQ MatMul
```

### QNN is BLOCKED, and the reason is definitive

```
Example.NPU.run_qdq(:qnn) -> {:error, "QNN execution provider is not supported in this build. "}
```

That is onnxruntime's own message. The base `onnxruntime-1.28.0` wheel's `libonnxruntime.so` is
**not compiled with `--use_qnn`**, so `SessionOptionsAppendExecutionProvider(session, "QNN", ...)`
is rejected outright.

**My earlier reasoning was wrong.** I read `ort`'s QNN `register()` on the `main` branch, saw it
call the generic string-based append, and concluded a *stock* libonnxruntime plus
`libonnxruntime_providers_qnn.so` would work. That is how the **old built-in/shared-provider** model
worked. But ORT 1.28 + `onnxruntime_qnn` 2.4.0 is the **plugin EP** model, which requires
`RegisterExecutionProviderLibrary(env, name, library_path)` (ORT >= 1.23 C API). The DeepWiki page
said exactly this and I explicitly discounted it in favour of the source. Wrong call; it cost a
build/flash cycle.

Corroborating evidence gathered before the error message existed:
- `/proc/self/maps` after a `:qnn` run: `libonnxruntime` **mapped**,
  `libonnxruntime_providers_qnn.so` and `libQnnHtp` **never mapped** -> ORT never even dlopen'd the
  provider.
- Falsification test: pointing `ORTEX_QNN_BACKEND_PATH` at `/nonexistent/libQnnHtp.so` still
  returned *correct numbers, faster*. Matching output values prove **nothing**.

### Two traps that made this hard to see, both now fixed in the fork

1. `ort`'s `apply_execution_providers()` (`src/execution_providers/mod.rs:231-259`) **swallows**
   registration failures unless the dispatch has `.error_on_failure()`, then returns `Ok(())` and
   lets onnxruntime fall back to CPU.
2. ortex has `// tracing_subscriber::fmt::init();` **commented out** (`model.rs:39-40`), so ort's
   `tracing::error!("An error occurred when attempting to register ...")` goes nowhere.

Together: a QNN session that silently runs on CPU, with correct results and no diagnostics. Our
fork now calls `.error_on_failure()` on the QNN dispatch, which is what surfaced the real message.
`Example.NPU.prove_qnn/1` automates the falsification check and returns
`:qnn_genuinely_used | :silently_on_cpu | :inconclusive`.

### rc.12 attempt: plugin EP now LOADS, backend still does not

Fork branch `../ortex` `qnn-rc12`, based on upstream **PR #47** ("Modernise, update to Ort
2.0.0-rc.11", MERGEABLE, +1012/-810) — worth reusing: it moves to rustler 0.37.1, ndarray 0.17.2,
and already makes `map_eps` return `Result` and error on unknown EP atoms (the silent-CPU trap I had
patched by hand). PR #46 (rc.10) is CONFLICTING and 2.6x larger; neither PR reaches rc.12.

**rc.12 is mandatory**: `Environment::register_ep_library` (the ORT >= 1.23
`RegisterExecutionProviderLibrary`) exists in rc.12 and **not** in rc.10/rc.11 — checked per tag.

Changes on top of PR #47:
- `ort` -> `2.0.0-rc.12`, `default-features = false`, features
  `std, ndarray, half, tracing, load-dynamic, api-24`. `api-24` implies `api-22`, which gates
  `register_ep_library`; `load-dynamic` also satisfies the cfg on `QNN::register()`.
- rc.12 moved `ort::tensor::TensorElementType` -> `ort::value::TensorElementType` (2 imports).
- QNN is **not** routed through `map_eps` any more: plugin EPs are selected with the V2 device API
  (`SessionBuilder::with_devices`, which calls `SessionOptionsAppendExecutionProvider_V2`), not by
  appending an `ExecutionProviderDispatch`. `utils::wants_qnn` filters `:qnn` out of the dispatch
  list and `model::init` takes a `use_qnn` flag and does register + `with_devices`.
- Every QNN failure is an error, never a silent CPU fallback (including "no QNN device found after
  registering ...", which lists the EP names actually seen).

**Progress that is real:** `/proc/self/maps` after a `:qnn` run now shows
`libonnxruntime_providers_qnn.so` **mapped**. On rc.8 it never was, and the session errored with
"QNN execution provider is not supported in this build." So registration + device selection work.

**Still blocked:** `libQnnHtp.so` / `libQnnSystem.so` / `libQnnHtpV68Skel.so` are **never mapped**,
and `prove_qnn/0` still reports `:silently_on_cpu`. Two candidate causes, untested:
1. The `backend_path` provider option is not reaching the plugin. `with_devices` options must be
   EP-name-prefixed (ort's own example uses `"CPUExecutionProvider.use_arena"`). We now pass both
   `"<ep_name_from_device>.backend_path"` and a bare `"backend_path"`; neither loaded the backend, so
   the real key may differ (possibly the *registration* name, `"QNN.backend_path"`).
2. The EP claims **no nodes** for the QDQ MatMul graph and therefore never initialises a backend.
   That would make the backend_path question moot.

Cheapest way to separate them: get the EP name and node assignment out of onnxruntime. Its own
logging is the direct route — ortex has `// tracing_subscriber::fmt::init();` commented out
(`model.rs:42-43`), and ORT's stderr goes to the console (tty1), not the SSH session, so wire a
subscriber that writes somewhere readable, or enable ORT session profiling (it emits a JSON with a
per-node EP assignment). Do that before changing more option keys by guesswork.

### PURE-RUST PROBE: the plumbing is solved. Recipe below.

`../qnn-probe` is a standalone Rust binary (no Elixir/rustler/BEAM) cross-compiled for the board and
run over SSH via `:os.cmd(... 2>&1)`, which is what finally made ONNX Runtime's own logs visible —
the missing diagnostic all along. Deploy with **sftp** (`nerves_ssh` has the sftpd subsystem, so
`sftp nerves.local` works; 1.2 MB binary to `/root`, `File.chmod!(path, 0o755)` to make it
executable).

**Confirmed working, in order:**
```
-- devices after register_ep_library("QNN", "/usr/lib/libonnxruntime_providers_qnn.so") --
  [0] ep="CPUExecutionProvider" vendor="ARM"      type=CPU
  [0] ep="QNN"                  vendor="Qualcomm" type=NPU     <- the NPU is discovered
INFO Creating QNN EP
INFO Create device.
     libQnnHtp mapped = true
     INFERENCE OK -> [38.0, 40.0, ... 52.0]
```

**The four things that had to be right** (each was a separate wrong assumption):

1. **ort >= rc.12 and the V2 device API.** `register_ep_library` + `SessionBuilder::with_devices`.
   Appending "QNN" by name gives "QNN execution provider is not supported in this build."
2. **The provider option key is `"QNN.backend_path"`** — the EP name from `Device::ep()` is literally
   `"QNN"`, not `"QNNExecutionProvider"`. onnxruntime turns it into config option
   `ep.qnn.backend_path`, visible in its "Session Options { ... config_options: {...} }" log line.
3. **The QNN backend MUST come from the onnxruntime_qnn 2.4.0 wheel, not QAIRT 2.42.** With
   `/usr/lib/libQnnHtp.so` (QAIRT 2.42): `QNN SetupBackend failed Unable to find a valid interface`.
   With the wheel's: works. This applies to the **V68 skel too** — pointing
   `ADSP_LIBRARY_PATH` at `/usr/lib/dsp` (QAIRT 2.42 skel) gives
   `QNN_DEVICE_ERROR_INVALID_CONFIG: Invalid config values`. So the accepted-risk version skew noted
   in `blobs/onnxruntime-qnn/README.md` was the actual blocker, exactly as suspected there.
   Set `DSP_LIBRARY_PATH` **and** `ADSP_LIBRARY_PATH` to the dir holding the wheel's skel.
4. **`htp_arch=68` must be passed explicitly.** Auto-detection fails with
   `Unable to get platform info: Failed to get HTP arch`; supplying `QNN.htp_arch=68` clears it.

**The one remaining blocker is the MODEL, not the stack:**
```
WARN QNN.backendValidateOpConfig() failed for node `MatMul3` of type `FullyConnected` with error 4000
```
The HTP rejects our hand-written QDQ MatMul (`example/priv/qdqmatmul.onnx`), so the EP claims no
nodes, never loads the skel, and inference falls back to CPU (correct values, ~20-50 us, `skel=false`).
Hand-authoring QDQ was the mistake: use onnxruntime's own quantizer
(`onnxruntime.quantization.quantize_static`, QDQ format, per-channel int8 weights) on a real model,
or a Qualcomm AI Hub pre-compiled context binary. Error 4000 is QNN op-config validation — most
likely the uint8 weights with scale 1.0 / zero-point 0 are not a legal FullyConnected quantisation.

**Iterate with the probe, not with firmware builds.** `ORTEX_QNN_OPTS="htp_arch=68,soc_model=..."`
appends arbitrary `QNN.*` provider options, so option/model experiments are one sftp + one
`:os.cmd` apart instead of a 5-minute build-flash cycle.

### Real AI Hub model: everything loads, execution is still 100% CPU

> **WRONG — SUPERSEDED.** See "THE NPU IS WORKING" below. The A/B in this section (QNN 32562 vs
> "CPU" 32660 us, identical output) had **both sides running on the NPU**: `ORTEX_QNN_SKIP=1` does
> not produce a CPU baseline when the DSP environment is configured, because ORT auto-selects the
> registered plugin EP (see the gotcha below). The identical outputs were identical precisely
> *because* both used the HTP. Re-measured properly, this same pose model is
> **888.3 ms/iter on CPU vs 25.1 ms/iter on the HTP — 35x.**

Model: `~/radxa-yolov11/aihub_pose_s/job_jgk9m4zy5_qdq_onnx/` (yolov11-pose-small, Qualcomm AI Hub
QDQ export) — `model.onnx` 524 KB + `model.data` 40 MB external weights, input `images`
f32 [1,3,640,640], output `output0` [1,56,8400], 1390 nodes
(566 DequantizeLinear / 470 QuantizeLinear / 97 Conv). A genuinely HTP-shaped graph, unlike the
hand-written QDQ MatMul, which the HTP rejected outright (`error code 4000`).

Two more requirements discovered with it:
5. **`libQnnHtpPrepare.so` (89 MB) is required.** Without it the session fails to commit:
   `Node '/model.0/conv/Conv_token_27' OpType:Conv with domain:com.ms.internal.nhwc was inserted
   using the NHWC format as requested by QNN, but was not selected by that EP`. So QNN's
   GetCapability *did* claim Conv nodes and request a layout transform, then declined them because
   it could not compile. Adding Prepare makes the session commit cleanly.
6. **`DSP_LIBRARY_PATH` order matters and uses `;`.** `"/root/qnnlibs;/usr/lib/dsp"` works;
   `"/usr/lib/dsp;/root/qnnlibs"` finds the QAIRT 2.42 skel first and gives
   `QNN_DEVICE_ERROR_INVALID_CONFIG` plus a 27x slowdown (886 ms).

**But it is not on the NPU.** A/B on the identical model and input:
```
QNN : 32562 us   first6=[15.946361, 22.673222, ...]
CPU : 32660 us   first6=[15.946361, 22.673222, ...]   (ORTEX_QNN_SKIP=1)
```
0.3% apart with bit-identical output — the QNN EP claims no nodes and everything executes on CPU,
while the session reports success and logs no error.

**Correction to an earlier check:** `QnnHtpV68Skel` absent from `/proc/self/maps` proves nothing.
The skel is a **Hexagon** ELF loaded onto the DSP over FastRPC; it never maps into the ARM process.
Wall-clock against a CPU baseline is the honest signal, which is why the probe has
`ORTEX_QNN_SKIP=1`.

`Some nodes were not assigned to the preferred execution providers` is generic ORT boilerplate and
is **not** evidence QNN took anything.

**Next diagnostic — stop guessing option keys, get the per-node assignment.** Enable ORT session
profiling (`enable_profiling` + `profile_file_prefix`); it writes a JSON where every node carries the
EP that ran it. That answers "did QNN claim any nodes, and if not which op rejected first" in one
run. QNN EP also accepts `profiling_level` and `qnn_saver_path` options for its own tracing. Two
loose threads to check while there: `libQnnSystem.so` is never mapped even on the working path, and
the earlier `Unable to get platform info: Failed to get HTP arch` suggests the EP may still not be
talking to the DSP properly — possibly needing `soc_model` alongside `htp_arch`, or the unsigned-PD
`fastrpc_shell_unsigned_3` reachable in the same `DSP_LIBRARY_PATH`.

### Python reference: ALSO does not reach the NPU, and exposes a harness discrepancy

Ran the vendor-path reference on the board — Buildroot's Python 3.14.5 + numpy 2.4.0 (matching the
`cp314` wheel ABI exactly), with the upstream `onnxruntime` 1.28.0 and `onnxruntime_qnn` 2.4.0
site-packages extracted to `/root/py` (18 MB tarball, unpacked with Erlang's `:erl_tar`; sftp's
`put -r` silently does nothing in batch mode). Script: `/root/ref.py`.

```
PY CPU | session providers: ['CPUExecutionProvider']   fastrpc fds: []
PY CPU | 30 iters: wall 26612 ms (887.1 ms/iter), process CPU 207116 ms (778% of wall)
PY QNN | registering QNNExecutionProvider from /root/py/onnxruntime_qnn/libonnxruntime_providers_qnn.so
PY QNN | session providers: ['CPUExecutionProvider']   fastrpc fds: []
PY QNN | 30 iters: wall 28172 ms (939.1 ms/iter), process CPU 219179 ms (778% of wall)
```

**Python does not use the NPU either — and fails earlier than the Rust path.** After
`register_execution_provider_library("QNNExecutionProvider", ...)` succeeds, the EP does not appear in
`sess.get_providers()` at all, and no `/dev/fastrpc-*` is ever opened. The Rust/`ort` path at least
got the graph *assigned* to `QNNExecutionProvider` in the placement report and opened
`/dev/fastrpc-cdsp-secure`. So the Elixir-facing stack is **ahead of** the vendor reference here, and
"just use Python" is not an escape hatch on this system.

### *** THE NPU IS WORKING: 38x. Both earlier verdicts were measurement errors. ***

Running the Rust probe's own CPU baseline against Python's on the *same* model finally gave a common
reference point, and it invalidates the retraction that used to be in this section. All four runs
below: `/root/det/model.onnx` (yolo11s QDQ), input `images` f32 [1,3,640,640], 30 iterations.

| harness | ms/iter | process CPU as % of wall | `first6` |
|---|---|---|---|
| Rust, `ORTEX_QNN_SKIP=1` (CPU) | 920.6 | 772% | `[28.048985, 29.758934, 30.953955, ...]` |
| Python, `SKIP_QNN=1` (CPU) | 887.1 | 778% | `[28.04898, 29.75893, 30.95395, ...]` ← identical |
| Python + QNN registered | 939.1 | 778% | identical to CPU — EP never selected |
| **Rust + QNN (`htp_arch=68`, burst)** | **24.2** | 595% | `[26.86368, 28.729078, 28.466757, ...]` |

Same measurement on the pose model (`/root/pose/model.onnx`, yolov11-pose-small QDQ): CPU
888.3 ms/iter (`first6=[14.324512, 21.682695, ...]`) vs HTP 25.1 ms/iter
(`first6=[15.946361, 22.673222, ...]`) — **35x**. Both models therefore land at ~23-25 ms/iter on the
HTP and ~890-920 ms/iter on the ARM cores.

The two independent CPU baselines agree to 4% and produce byte-identical outputs, so the harnesses
are sound and mutually validating. Against that real baseline the QNN path is **38x faster**
(920.6 → 24.2 ms/iter), and first-run-including-graph-prepare is 864 → 36 ms. 24 ms/iter for
int8 yolo11s is the expected HTP v68 ballpark. The differing `first6` is the expected consequence of
HTP quantized arithmetic rather than a bug.

**Falsification test (the one that actually settles it).** Same QNN configuration, but with the
Hexagon skel made unreachable — `ADSP_LIBRARY_PATH=/nonexistent DSP_LIBRARY_PATH=/nonexistent`:
```
session OK; libQnnHtp mapped now = true
first run (incl. graph prepare): 871 ms
3 iters: wall 2511 ms (837.1 ms/iter), process CPU 19190 ms (764% of wall)
```
Remove the DSP-side code and the identical configuration collapses to exactly CPU speed **while
still reporting `session OK` and logging no error**. The Hexagon skel is load-bearing, therefore the
compute is on the DSP. This also documents the silent-CPU-fallback failure mode directly.

**Why the retraction was wrong: CPU%-of-wall is not an offload signal.** The retracted verdict
compared "CPU 27.8 ms/iter" against "NPU 25.5 ms/iter" and concluded no acceleration — but that
27.8 ms figure was never a CPU baseline (the real one is 920 ms/iter; it was a mislabelled QNN run).
The 595%-of-wall that looked damning is ORT's intra-op thread pool **spin-waiting** on the DSP:
24.2 ms × ~6 spinning cores ≈ 143 ms of charged CPU per iteration doing nothing. Spin-wait and
compute are indistinguishable in `/proc/self/stat`, so that ratio cannot distinguish them either.
The wall-clock-against-a-real-baseline plus remove-the-accelerator pair is the test that can.

**THE GOTCHA THAT CAUSED EVERY EARLIER MISREADING: ORT auto-selects a registered plugin EP.**
Once `register_ep_library()` has been called and the HTP backend can initialise, a *plain*
`Session::builder()` with no EPs and no `with_devices()` still runs on the NPU:
```
(QNN skipped: CPU baseline)          <- the probe's own ORTEX_QNN_SKIP=1 path
first run (incl. graph prepare): 36 ms
5 iters: wall 145 ms (29.0 ms/iter), process CPU 810 ms (559% of wall)
```
29 ms/iter, i.e. the NPU. So **`ORTEX_QNN_SKIP=1` is only a genuine CPU baseline when the HTP
backend cannot come up** — in practice, when `DSP_LIBRARY_PATH`/`ADSP_LIBRARY_PATH`/
`ORTEX_QNN_BACKEND_PATH` are left unset. Every "no difference between QNN and CPU" result in this
document came from an A/B where both arms were on the NPU. For a trustworthy baseline, either unset
the DSP environment or point `ADSP_LIBRARY_PATH` at a nonexistent directory.

Two useful consequences: on this ORT version an Elixir caller may get the NPU without asking for it
(good for us, but it means `Ortex.load/2` without `:qnn` is not a CPU guarantee), and any future
benchmark in this repo must state which of the two baseline methods it used.

**Dead hypothesis: signed vs unsigned PD.** `fastrpc fds: ["/dev/dma_heap/system",
"/dev/fastrpc-cdsp-secure"]` appears in the **CPU baseline too** — it is opened when `libQnnHtp.so`
is loaded, before any execution. It was never evidence about execution, so there is nothing to fix
here; `QnnHtpDevice_CustomConfig_t`/`unsignedPD` is not needed.

**Python is the one that does not work.** `register_execution_provider_library("QNNExecutionProvider",
...)` succeeds, then the EP never appears in `sess.get_providers()` and no `/dev/fastrpc-*` is
opened. Passing `providers=[(name, opts), "CPUExecutionProvider"]` apparently does not route a
*plugin* EP on this build — the V2 device path (`with_devices`) that the Rust side uses is what
selects it. So the Elixir/Rust stack is **ahead of** the vendor Python reference, and "just use
Python" is not an escape hatch here.

### Elixir-facing YOLO: Example.Yolo, and the bug that hid the NPU from Elixir

`example/lib/example/yolo.ex` runs a YOLO ONNX model on an image file end to end:
`Example.Yolo.detect("/root/bus.jpg")` returns class, score and `{x1,y1,x2,y2}` boxes in the original
image's coordinates. `load/1` keeps a session, `run/2` returns the raw output tensor for heads the
decoder does not understand, `bench/2` times it. Verified on-device against the canonical Ultralytics
test images: bus.jpg -> bus + 4 persons, zidane.jpg -> 2 persons + 2 ties, boxes matching the
published reference.

**The bug: `System.put_env/2` cannot configure this stack.** Since OTP 21, `os:putenv` writes
Erlang's own environment table and leaves the OS `environ` alone. So `ORTEX_QNN_BACKEND_PATH`,
`DSP_LIBRARY_PATH` and friends set from Elixir were invisible to the ortex NIF *and* to the QNN
libraries' own `getenv`. Every session kept the default `/usr/lib/libQnnHtp.so` - the incompatible
QAIRT 2.42 build - and ran on the ARM cores, silently. 881 ms/iter before, **43 ms/iter** after.

The fix is in the ortex fork (`4052d41`): `Ortex.load/4` takes a `qnn_opts` keyword list, and keys
prefixed `env.` are set in the real process environment by the NIF. Elixir callers therefore pass
configuration as arguments; nothing depends on the environment the BEAM happened to start with.

**What found it: `ORTEX_TRACE`.** ort reports EP registration, device selection and per-node
placement through `tracing`, and ortex installed no subscriber, so all of it was discarded - which is
precisely why a silent CPU fallback looked identical to a working session from Elixir. The fork now
writes that plus onnxruntime's VERBOSE log to a file (a NIF's stdout goes to the console, unreadable
over ssh). The trace file failing to appear *at all* is what exposed the putenv problem. Three
hypotheses were burned guessing before instrumenting: `htp_arch`, graph optimization level, and a
stray unprefixed option key. Instrument first next time.

**Preprocessing, not inference, is the bottleneck.** The obvious Nx implementation
(`Nx.pad |> Nx.divide |> Nx.transpose`) took **9.0 s** per 640x640 image - 200x the inference it was
feeding - because there is no EXLA here and BinaryBackend evaluates transpose element-by-element.
Rewritten as one binary-comprehension pass per channel, emitting the letterbox padding directly as
f32: **110-165 ms**. Any Nx elementwise or transpose work on image-sized tensors is a trap on this
target.

**Two traps for anyone benchmarking from a long-lived BEAM**, both now documented in `bench/2`:
the first QNN session's DSP configuration is cached for the OS process lifetime, so hiding the skel
later has no effect; and going from a poisoned DSP configuration to a working one **takes the VM
down** (observed - the node rebooted mid-benchmark). A CPU baseline needs `ep: :cpu_forced` to be
the first inference after boot, or the standalone `qnn-probe`.

Costs at 640x640 with yolo11s QDQ: preprocess 70-150 ms, HTP inference ~43 ms (~21 fps measured over
10 iterations), ARM inference ~865 ms. The 43 ms against the probe's 24 ms is ortex marshalling
~7.7 MB per call (4.9 MB input tensor in, 2.8 MB output out).

**Still on `/root/qnnlibs`.** `Example.Yolo.qnn_opts/1` looks in `/usr/lib/onnxruntime-qnn` first and
falls back to `/root/qnnlibs`, where the working QNN 2.4.0 set was placed by hand. Shipping it in the
image means vendoring ~107 MB into `blobs/onnxruntime-qnn/usr/lib/onnxruntime-qnn/` (of which
`libQnnHtpPrepare.so` is 85 MB) under a prefix that does not collide with qairt-runtime's
`/usr/lib/libQnnHtp.so`, plus a system rebuild. Not done yet - the licensing question below applies
to these files too.

### EXLA on the board: it works, and what it is actually worth

`xla_extension-0.10.0-**aarch64-linux-gnu**-cpu` is published, so no source build of XLA is needed.
Verified before committing to it: max symbol requirement `GLIBC_2.27`; needs only
libc/libm/libpthread/librt/libdl/libstdc++/libgcc_s, and `libstdc++.so.6.0.34` + `libgcc_s.so.1` are
already in `/lib`. `libxla_extension.so` is **392 MB** on disk, ~56 MB compressed — firmware went
165 MB -> 240 MB.

Cross-compiling it needs one knob, set in `example/mix.exs` because Mix evaluates that file before
compiling any dependency: `XLA_TARGET_PLATFORM=aarch64-linux-gnu`. The `xla` package then fetches the
aarch64 archive instead of a host one. EXLA's own `libexla.so` cross-compiles without any patching —
its Makefile already has an `ifeq ($(CROSSCOMPILE),)` branch and builds through `$(CXX)`, so Nerves'
toolchain is picked up. `RPATH=$ORIGIN/xla_extension/lib` resolves inside the release. On device:
`Nx.default_backend() == {EXLA.Backend, []}`, first op 2000 ms (client init), second 4 ms.

**Three traps, all measured:**

1. **`EXLA.Backend` alone buys ~10%.** It executes each Nx op as its own XLA computation with a host
   round-trip. Whole `preprocess` (median of 7, includes the 15 ms `StbImage.resize`): **70 ms**
   pure-binary fallback, **65 ms** op-by-op EXLA, **52 ms** fused in a `defn`. Getting the win
   requires `config :nx, default_defn_options: [compiler: EXLA]` *and* wrapping the pipeline in a
   `defn` — without the config, `defn` runs through Nx's interpreter and is slower still.
2. **A prepared frame must not stay in an XLA buffer.** ortex pulls its inputs across with
   `Nx.backend_transfer`, which *deletes* the source. So an EXLA-resident input works exactly once
   and the second inference raises `ToLiteral() called on deleted or donated buffer`. `to_input_nx`
   ends with `Nx.backend_copy(Nx.BinaryBackend)`. That also removed a per-inference device
   round-trip: 77 ms -> 32 ms per `Ortex.run`.
3. **The remaining cost is data movement, not arithmetic.** ~1 MB u8 in and 4.9 MB f32 out per frame.
   Decode (80 ms) and resize (15 ms) are already C and untouchable by XLA.

Verified equivalent to the binary fallback: identical detections, and inputs agreeing to 1 ULP
(max abs diff 5.96e-8 — the fallback divides in double and narrows to f32, XLA divides in f32).

**Verdict.** Worth keeping for what it enables (`defn`, Axon, custom numerics on device), not for this
pipeline: 392 MB to take preprocessing from 70 ms to 52 ms, while decode+resize+inference are 127 ms.
A small C/Rust NIF doing resize+planar in one pass would beat it for ~50 KB. Model throughput is
**27-31 fps** either way; end-to-end from a fresh JPEG is ~5-9 fps.

### Build trap: plain `mix compile` cross-compiles rustler NIFs, `mix deps.compile --force` does not

`config :ortex, Ortex.Native, target: "aarch64-unknown-linux-gnu"` is honoured by
`mix deps.compile ortex --force` but **not** by a plain `mix compile` that happens to recompile
ortex's `.ex` files — that path silently produced an **x86-64** NIF, which only surfaced two steps
later as `scrub-otp-release.sh: ERROR: Unexpected executable format`. Fixed by pinning the target in
cargo's own environment in `shell.nix` (`CARGO_BUILD_TARGET` plus the per-target linker/CC/AR and the
host-side `CC_x86_64_*` overrides), so both Mix paths agree regardless of config visibility.
Regression-tested by touching `lib/ortex.ex` and running plain `mix compile`.

### Overnight soak in progress — started 2026-07-27 ~01:50 UTC

`Example.Soak` runs inference back-to-back forever and appends one row per minute to
**`/data/soak.csv`** (51 columns): fps / mean / min / max / errors for that interval only, all 34
thermal zones in millidegrees, 3 cpufreq policies, and the 4 cooling devices' `cur_state`.
Read it with `Example.Soak.summary()`; stop with `Example.Soak.disable()`.

It survives reboots by design: `enable/1` writes `/data/soak.enabled` and `Example.Application`
restarts the soak at boot whenever that file exists. Already proved itself — the device rebooted
during setup and the log shows `Soak flag present; resuming soak`.

Three things that had to be got right, each of which had already bitten once:

* **Start it under the application supervisor, not `start_link` from the IEx session.** Linking to an
  SSH session means closing the terminal ends the overnight run.
* **`:transient`, and stop via `Supervisor.terminate_child`.** A `:permanent` child would be restarted
  by the supervisor immediately after `disable/0` stopped it.
* **Rows are written with `:sync`.** An unclean reset cost exactly the header and the first data row
  from an unflushed page cache; `ensure_header` now also rotates a headerless file aside rather than
  appending a header mid-file.

`init/1` never fails hard — it retries setup every 15 s — because the CDSP can still be establishing
its FastRPC session at boot, and a stopping child would put the whole application into a restart loop
unattended.

**Already visible in the first two samples, and it is the headline for tomorrow: the board throttles
hard and fast.** At t=60 s cpu0 88.4 degC, nspss0 83.3, ddr 84.9, skin 73.3, cooling state 6/9 on all
three cpufreq domains, 24.0 fps. At t=120 s: nspss0 84.1, skin 74.2, cooling state **7/9**,
22.65 fps. Idle was 37-41 degC. So the overnight numbers will mostly describe the *throttled* steady
state — which is the useful number for a real deployment, but it is not the 27-31 fps that
`bench/2` reports in a short burst.

Worth trying next, and probably a real win: most of that heat is ARM, not NPU. ONNX Runtime's thread
pool **spin-waits** while the HTP computes (~6 cores at 100% for a 32 ms inference, see the
CPU%-of-wall note above), so the cores are burning power doing nothing and then throttling the whole
package. Capping the EP's intra-op threads should cut CPU temperature and may well *raise* sustained
NPU throughput by keeping the die out of thermal limit.

### The loading recipe (all of this remains correct)

Proven by onnxruntime's own placement report (session log severity VERBOSE):
```
Node placements
 Node(s) placed on [QNNExecutionProvider]. Number of nodes: 1
   QNNExecutionProvider_5600499331747928002_1
 Node(s) placed on [CPUExecutionProvider]. Number of nodes: 2
   QuantizeLinear (QcQuantizeOp_images_q)
   DequantizeLinear (QcQuantizeOp_output0_dq)
```
The whole 1390-node yolov11-pose graph is fused into **one** QNN node on the NPU; only the input
quantize / output dequantize stay on CPU (normal boundary conversion).

**Seven requirements, all mandatory:**
1. `ort >= 2.0.0-rc.12` — first version with `Environment::register_ep_library`.
2. Select via the **V2 device API** (`SessionBuilder::with_devices`), not by appending an
   `ExecutionProviderDispatch`.
3. **Register the library as `"QNNExecutionProvider"`, not `"QNN"`.** This is load-bearing and cost
   the most time: with `"QNN"` the session still succeeds and reports a QNN device, but runs at CPU
   speed (32.8 ms vs 27.5 ms). `onnxruntime_qnn`'s Python package hardcodes
   `EP_NAME = "QNNExecutionProvider"` — match it. `Device::ep()` merely echoes whatever name you
   registered, so it is *not* a way to discover the right one.
4. Provider options are prefixed with that name: `"QNNExecutionProvider.backend_path"` etc.
   onnxruntime rewrites them to `ep.qnn.*`, visible in its "Session Options { config_options: {...} }"
   log line.
5. QNN backend + V68 skel **must** come from the `onnxruntime_qnn` 2.4.0 wheel, not QAIRT 2.42
   (`Unable to find a valid interface` / `QNN_DEVICE_ERROR_INVALID_CONFIG`).
6. `libQnnHtpPrepare.so` (89 MB) required, else the session will not commit
   (`Conv ... NHWC as requested by QNN, but was not selected by that EP`).
7. `htp_arch=68` explicitly (auto-detect fails: `Failed to get HTP arch`), and
   `htp_performance_mode=burst` for the speed — the default mode runs at CPU speed.

Environment that works:
```sh
ORT_DYLIB_PATH=/usr/lib/libonnxruntime.so
LD_LIBRARY_PATH=<qnnlibs>:/usr/lib
DSP_LIBRARY_PATH="<qnnlibs>;/usr/lib/dsp"     # ';' separated, order matters
ADSP_LIBRARY_PATH="<qnnlibs>;/usr/lib/dsp"    # qnnlibs FIRST or you get INVALID_CONFIG
# options: backend_path=<qnnlibs>/libQnnHtp.so, htp_arch=68, htp_performance_mode=burst
```

**Measured on yolov11-pose-small QDQ (AI Hub), 1x3x640x640, steady state:**
| config | time |
|---|---|
| CPU only | 31431 us |
| NPU, default power mode | 32655 us |
| **NPU, burst** | **27461 us** |
| NPU, sustained_high_performance | 27496 us |

Outputs bit-identical CPU vs NPU — expected for QDQ int8, not a red flag.

**Only 1.14x over CPU, so there is performance left on the table.** Likely causes, in order:
the per-frame CPU-side `QuantizeLinear` of 1.2M f32 inputs and `DequantizeLinear` of the output
(use int8/uint8 model I/O to remove it); no context caching
(`qnn_context_cache_enable` + `qnn_context_cache_path` avoids recompiling and can change scheduling);
and `libQnnSystem.so` never being mapped, which may indicate a partially degraded path.
For reference, AI Hub quotes single-digit ms for this model class on QCS6490.

### Options to actually get the NPU (pick one)

1. **Bump the fork's `ort` to rc.12+ and use plugin registration.** `RegisterExecutionProviderLibrary`
   exists in newer ort (`src/environment.rs`, `src/ep/mod.rs`, `ort-sys`). Cost: rc.8 -> rc.12 is an
   API break for ortex's session/tensor code. ~1-2 days. **Recommended.**
2. Build ONNX Runtime from source with `--use_qnn` for aarch64 Linux. Multi-day, and Qualcomm does
   not officially support the QNN SDK on aarch64 Linux (microsoft/onnxruntime#21203).
3. Python + the wheels `radxa-q6a-yocto` already validated on this SoC. Proven, but adds CPython +
   numpy to the image and abandons the Elixir-native path.

Note `libonnxruntime_providers_qnn.so` ships mode 0644 while our other libs are 0755. `dlopen`
does not require `+x`, and it is not the cause here, but worth normalising if the plugin path is
pursued.

**A** — `package/onnxruntime-qnn` + `blobs/onnxruntime-qnn` vendor 3 libs from the same upstream
wheels `radxa-q6a-yocto` validated (cached at `radxa-q6a-yocto/build/downloads/`):
`libonnxruntime.so.1.28.0`, `libonnxruntime_providers_shared.so`,
`libonnxruntime_providers_qnn.so`. We deliberately do **not** vendor the wheel's own QNN backend —
`blobs/qairt-runtime` already ships a board-validated QAIRT 2.42 set, and a second one would
collide on `/usr/lib/libQnnHtp.so` and on the `libQnnHtpV68Skel.so` name in `DSP_LIBRARY_PATH`.
Accepted risk: ORT 1.28's EP was built against its own bundled QNN, not 2.42. See
`blobs/onnxruntime-qnn/README.md` for the fallback if the EP rejects the backend.

**B** — the recipe that works:
```sh
RB=$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin
TC=$HOME/.local/share/nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-linux_x86_64-15.3.0
export PATH=$RB:$TC/bin:$PATH
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-nerves-linux-gnu-gcc
export CC_aarch64_unknown_linux_gnu=aarch64-nerves-linux-gnu-gcc
cargo build --release --target aarch64-unknown-linux-gnu
```
Notes: nixpkgs `rustc` ships only the host std, so a rustup toolchain is needed
(`rustup target add aarch64-unknown-linux-gnu`); rustup's binaries *do* run on NixOS unpatched.
nix's rustup wrapper does **not** create `~/.cargo/bin` shims — call
`~/.rustup/toolchains/*/bin/cargo` directly. Rust's target triple is
`aarch64-unknown-linux-gnu` while the toolchain is `aarch64-nerves-linux-gnu`: different vendor,
same ABI, so linking is fine.

**C** — fork at `../ortex` (`elixir-nx/ortex` @ 55dc3de). Changes:
- `ort` → `default-features = false, features = ["load-dynamic", "ndarray", "half"]`. Default
  features enable `download-binaries`, which fetches a **host-arch** libonnxruntime — useless when
  cross-compiling. `load-dynamic` dlopen()s ours from `ORT_DYLIB_PATH` instead.
- `constants.rs`: `QNN` const + `qnn` atom.
- `utils.rs`: `qnn_ep()` using `ORTEX_QNN_BACKEND_PATH` (default `/usr/lib/libQnnHtp.so`), since
  `map_eps` only receives bare atoms and has nowhere to pass options.
- `map_eps`'s `_ =>` arm now **warns** before falling back to CPU. Previously a typo'd or
  unsupported EP atom gave working inference with no acceleration and no error — a silent trap.
- Perf-mode/profiling intentionally not wired: in rc.8 `PerformanceMode` is not re-exported at the
  `ort` root, so naming it fails to compile. Revisit if the ort dep is bumped (upstream is rc.12).

## Decisions and gotchas worth not re-deriving

- **A `SITE_METHOD = local` package does NOT rebuild when you edit its source tree.** Buildroot keys
  the build dir and the per-package stamps off `<PKG>_VERSION`, so editing `blobs/qairt-runtime/`
  left the stamp valid: the build exited 0, the artifact was even repackaged, and the new blobs were
  silently absent from the image. **Bump `<PKG>_VERSION` whenever the vendored tree changes** — that
  is the correct signal (the blob set really did change), it forces a fresh build dir, and unlike a
  `dirclean` it does not require driving Buildroot by hand as root. Applies to every local-site
  package here: `qairt-runtime`, `qcom-dsp-firmware`, `qcom-dsp-shell`, `aic8800`.
  Tell-tale: the build log has no `>>> <pkg> <version> Installing to target` line for it.
- **NEVER `docker run … make` against the build volume as root.** The builder image runs as root
  even when you pass `--env UID=1000 --env GID=100`, so ad-hoc container commands leave
  root-owned `build/`, `host/` and `images/` while Nerves' own build runs as `1000:100`. The result
  is *non-deterministic* write failures scattered across the kernel tree, with no compiler error:
  ```
  fixdep: error opening file: kernel/time/.posix-timers.o.d: No such file or directory
  ar: kernel/time/posix-timers.o: No such file or directory   → Error 123
  ```
  Six unrelated subsystems failed this way (`fs/nfs`, `kernel/bpf`, `net/ipv4`, `atl1c`,
  `brcmfmac`, `iwlwifi`) on a *freshly dircleaned* tree, which is the tell: stale state cannot
  explain a clean tree failing. Disk (754G free) and memory (30Gi) were both fine.
  Repair: `docker run --rm -v <volume>:/v alpine chown -R 1000:100 /v`, then dirclean the affected
  packages and rebuild through `mix`. Prefer `mix` for everything; if you must drive Buildroot
  directly, chown afterwards.
- **Only ever run ONE build at a time.** All builds share the single Docker volume and Buildroot
  has no locking. Two concurrent `mix compile`/`mix firmware` runs corrupt each other — earlier in
  the same session this killed the artifact `tar` step with
  `file changed as we read it` / `File removed before we read it`.
- **`mix compile` skips Buildroot entirely when no `package_files()` input changed** — exit 0, zero
  work done. If you fix something *inside* the volume, mix will not notice. Changing a
  `package_files()` file (e.g. `linux-dragon-q6a.fragment`) is what forces a real rebuild *and* a
  fresh artifact; that is the reliable way to propagate a fix, not `mix nerves.artifact` (which did
  not refresh the extracted artifact cache at
  `~/.local/share/nerves/artifacts/<system>-portable-<vsn>/`).
- **Changing `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION` does NOT rebuild from the new tree.**
  Buildroot keys off `build/linux-custom/.stamp_downloaded` + `.stamp_extracted`; if they exist it
  never fetches the new tarball, silently rebuilds the OLD sources against the new fragment, and
  then fails in `linux-legal-info` with
  `cp: cannot stat '/nerves/dl/linux/<sha>.tar.gz': No such file or directory` — a *download* error
  that is really a *stale-source* error. Tell-tale: `grep SUBLEVEL build/linux-custom/Makefile`
  still reads the old tree's value, and the extract stamps are older than `.stamp_built`.
  Fix (not a raw `rm -rf`, which the fable5 risk-guard blocks for container paths):
  ```sh
  docker run --rm -v <build-volume>:/nerves/project \
    -v "$PWD/deps/nerves_system_br":/nerves/env/platform:ro \
    -v "$PWD":/nerves/env/nerves_system_dragon_q6a:ro \
    -w /nerves/project fermuch/nerves-dragon-q6a-builder:latest make linux-dirclean
  ```
  The build volume name is in `.nerves/artifacts/<system>-portable-<vsn>/.docker_id`.
  `/nerves/env/platform` is `deps/nerves_system_br`. Costs a kernel rebuild only.
- **`mix compile 2>&1 | tail -N` reports tail's exit code, not the build's.** A failed build looks
  like `exit 0`. Always redirect to a file and check the build's own status.
- **The task #12 gate found a symbol the plan missed: `CONFIG_TYPEC`.**
  `drivers/phy/qualcomm/Kconfig:59-66` gates the combo PHY on **two** dependencies —
  `depends on TYPEC || TYPEC=n` *and* `depends on DRM || DRM=n`. The plan only mentioned the DRM
  one, so with `TYPEC=m` in the base defconfig `PHY_QCOM_QMP_COMBO` stayed `=m` even after
  `DRM=y`, and dragged `DRM_AUX_BRIDGE` down with it. Adding `CONFIG_TYPEC=y` fixed both. This
  matters for display: the combo PHY drives USB3 *and* DisplayPort, which is how HDMI reaches the
  RA620 bridge.
- **`DRM_AUX_BRIDGE` cannot be set from a fragment.** It is a hidden symbol (bare `tristate`, no
  prompt, `drivers/gpu/drm/bridge/Kconfig:15-16`); it only follows its selector
  (`select DRM_AUX_BRIDGE if DRM_BRIDGE` in `PHY_QCOM_QMP_COMBO`). Verify it in the merged
  `.config`, never assert it in the fragment.
- **`qemu-smoke.sh <a-prebuilt.fw>` fails its IEx check if that .fw was built with
  `NERVES_CONSOLE=tty1`.** The script only exports `NERVES_CONSOLE=ttyAMA0` when it builds the
  firmware itself (`qemu-smoke.sh:87-99`); a passed-in `.fw` is used as-is. A tty1 build puts IEx
  on the framebuffer console, which QEMU's serial harness cannot see, so you get
  `[FAIL] IEx console` on a perfectly good image. The tell is in the serial log:
  `erlinit: The shell will be launched on tty 'tty1'.` The first three checks (GRUB slot, kernel
  banner, userspace/erlinit) still validate the boot chain. For a clean 5/5 run the script's own
  build, or `NERVES_CONSOLE=ttyAMA0`.
- **Buildroot leaves stale module trees in `target/` across a kernel-version change.** After the B7
  switch, `target/lib/modules/` held BOTH `6.18.0` (73.9M, Deka) and `6.18.2` (72.8M, radxa), so
  the shipped rootfs carried ~74 MB of dead modules — 1370 stale `.ko` next to 1367 live ones.
  `make linux-dirclean` clears the *build* dir but Buildroot never removes previously *installed*
  files, and it has no incremental fix; only `make clean` + a full rebuild (~2h) guarantees it.
  Functionally inert (`modprobe` resolves against `uname -r`), so it does not affect the Phase 0
  measurement — but do a clean rebuild before any release, and treat it as a warning that anything
  else dropped from the config may also still be sitting in `target/`.
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
- **RESOLVED 2026-07-25 on hardware — B6 is outcome 1, GRUB is fine.** The board boots our image
  from microSD: GRUB → kernel → erlinit, with erlinit's message visible on HDMI. Firmware
  `LoadImage()` accepts our ~39 MiB `EFI_STUB` kernel; no MeasureBoot abort. **Do not apply
  `CONFIG_EFI_ZBOOT`. Do not port systemd-boot.** The Yocto UKI failure was about PE layout, not
  payload size. See `BRINGUP.md` §3b. The stale risk analysis below is kept only for context.
- **`mix firmware.image` + `dd` produces a card EDK2 will not even offer as a boot device.** Use
  `mix firmware.burn` (fwup straight to `/dev/sdX`). The `.img` is a fixed 4.75 GiB image whose GPT
  hard-codes that geometry, so on a larger card the backup GPT is not at the last LBA and
  `last_usable_lba` is wrong — `fdisk` warns "The backup GPT table is not on the end of the device"
  and "GPT PMBR size mismatch". Linux tolerates it; EDK2 evidently does not, and the symptom is no
  boot entry at all (not a GRUB error, not a rescue prompt — nothing). The image is otherwise
  structurally perfect, so this is a *geometry* bug, not a content bug. Salvage: `sgdisk -e`.
  Also note `expand = true` (`fwup.conf:169`) is inert when the target is a file.
- **Superseded top risk (kept for context):** GRUB's arm64 loader boots the kernel via
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

<!-- AUTO-HANDOFF (PreCompact/auto) 2026-07-26T19:40:23Z -->
### Compaction handoff — 2026-07-26T19:40:23Z
- Git: branch `main`, 1 uncommitted file(s): WORKING_NOTES.md 
- Last verification run recorded: 2026-07-26T19:36:22Z	T=/tmp/claude-1000/-home-fermuch-Documents-Dev-AYVU-nerves-system-dragon-q6a/b5e1265e-3d92-4e4c-9105-598d18a6100e/scratc
- RESUME: re-read the Task/Status/Next-action sections above; trust this file over recollection.
