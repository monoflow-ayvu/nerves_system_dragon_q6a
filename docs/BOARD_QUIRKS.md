# Radxa Dragon Q6A (QCS6490) — board quirks and hard-won practice

Everything in here was measured on the actual board, not read off a datasheet. Where something is a
hypothesis rather than a result it says so explicitly.

Written to be read cold, with no prior context. If you only read one section, read the next one.

---

## 0. The five traps that cost the most time

1. **`Nx.backend_transfer(tensor)` defaults to `Nx.BinaryBackend`, not `Nx.default_backend()`.**
   Get this wrong and every Nx op runs element-by-element even with EXLA installed and configured.
   It cost a 1143 ms decode (30x the inference) and, separately, a 9.0 s image preprocess.
   Always `Nx.backend_transfer(t, Nx.default_backend())` — or `Nx.backend_copy/2`, see trap 4.

2. **`System.put_env/2` does not reach NIFs or C libraries.** Since OTP 21, `os:putenv` writes
   Erlang's own environment table and leaves the process `environ` untouched. So nothing you set from
   Elixir is visible to `getenv()` in onnxruntime or the QNN libraries. Configuration must be passed
   as arguments (see `Ortex.load/4`'s `qnn_opts`, and its `env.*` keys which the NIF pushes into the
   real environ).

3. **The cpufreq governor is not a power preference on this board, it is a correctness-of-performance
   setting.** With onnxruntime's spin-wait disabled there is no CPU load for `schedutil` to react to,
   the cores park at 691 MHz, and NPU throughput *halves*. The kernel now defaults to `performance`.

4. **`Nx.backend_transfer/2` DELETES the source tensor.** ortex pulls its inputs across with it, so a
   preprocessed frame held in an EXLA buffer works exactly once and then raises
   `ToLiteral() called on deleted or donated buffer`. Use `Nx.backend_copy/2` for anything you intend
   to reuse.

5. **A missing NIF fails at BOOT, not at build, and `mix compile` will not notice a deleted one.**
   Mix's staleness check only looks at sources. A gitignored-then-deleted `priv/native/ortex.so`
   produced a firmware that crashed the slot with `on_load_function_failed`; only the A/B rollback
   saved the board. `example/mix.exs` now has a `verify_nifs/1` release step — keep it.

---

## 1. Board facts

| | |
|---|---|
| SoC | Qualcomm QCS6490 (sc7280 family), 8 cores in 3 cpufreq policies |
| Max clocks | 1958 MHz (policy0, little) / 2400 (policy4, mid) / 2707 (policy7, big) |
| RAM | 11.9 GB usable |
| NPU | Hexagon NSP, HTP **v68** |
| **VTCM** | **2 MB usable** — `vtcm_mb=4` and above fail with `Failed to create Qnn graph` |
| GPU | Adreno (`3d00000.gpu`, devfreq, 315–812 MHz) — unusable for tensor math, see §5 |
| Thermal zones | 34, incl. `nspss0/1-thermal` (the NPU), `msm-skin-thermal` (case) |
| NSP trip points | **90 °C "hot", 110 °C critical** |
| CPU trip points | 90 passive / 95 / 110 critical, 2 bound cooling devices |
| DSP carveouts (device tree) | `cdsp@8e000000` 30 MB, `adsp@8b800000` 40 MB, `adsp-rpc-remote-heap` 8 MB |
| Power draw | ~5.5 W running two models with full decode; 7 W peak ever observed |

The DTB comes from **UEFI in SPI-NOR**. Do not add `devicetree` to `grub.cfg` — the firmware supplies
it and overriding it is wrong. A copy lives at `/usr/share/dtb/` purely as a bench reference.

### The NPU throttles itself, and Linux cannot see it

`nspss0/1-thermal` have **zero bound cooling devices** and there is no devfreq node for the NSP.
Mitigation happens inside the DSP (QNN/HTP's own DVFS), invisible to `/sys/class/thermal/cooling_device*`.

Observed directly: with the NSP at 94–96.6 °C for 15 minutes, aggregate throughput fell **22%**
(45.4 → 35.1 fps) while every `cool_*` state read `0`. When the NSP came back to ~81 °C, throughput
returned to 45 fps.

**So `cool_*` state 0 is NOT evidence of no throttling.** The real signals are `nspss0-thermal`
crossing ~90 °C, and fps itself. Sustained-throughput claims need both a sub-trip NSP temperature and
a flat fps trend.

---

## 2. Build, flash, update

Everything runs inside `nix-shell shell.nix`, which exports `MIX_TARGET=dragon_q6a`, puts the Nerves
cross toolchain on `PATH`, and pins cargo's target (see below).

```sh
nix-shell shell.nix --run 'cd example && mix firmware'                    # build
nix-shell shell.nix --run 'cd example && mix upload nerves.local'         # OTA to the inactive slot
nix-shell shell.nix --run 'cd example && mix firmware.burn'               # write an SD card
```

### Rules

* **Use `mix firmware.burn` for SD cards.** `mix firmware.image` + `dd` produces a card the board will
  not even offer as a boot device — the GPT geometry is only right when fwup writes the device directly.

* **`mix upload` output tells you whether it worked.** `Success! Elapsed time: …` means the transfer
  completed. **`the firmware update was applied and the device is likely rebooting` is a guess** printed
  when the connection drops mid-transfer — the upload may be incomplete. Verify.

* **Verify the slot actually switched.** Checks race the reboot constantly; poll until the board has
  actually restarted, then compare:

  ```elixir
  Nerves.Runtime.KV.get("nerves_fw_active")            # "a" | "b"
  Nerves.Runtime.KV.get_all()["a.nerves_fw_uuid"]      # against `fwup -m -i example.fw | grep uuid`
  ```

  If the active slot still holds the *old* uuid, the new firmware either did not boot or was rolled
  back — go to §7.

* **Editing anything in `package_files()`** (`nerves_defconfig`, `linux-dragon-q6a.fragment`,
  `fwup.conf`, `Dockerfile`, `rootfs_overlay/`, `blobs/`) invalidates the system artifact and triggers
  a Buildroot rebuild. Batch such edits.

* **A/B rollback works and has saved the board.** `nerves_fw_autovalidate=0`; a `StartupGuard` validates
  only once the application is genuinely up. A slot that fails to boot reverts to the previous one.

* **`/root` (the app data partition) is shared between slots.** This is how you debug a slot that would
  not boot — its `erl_crash.dump` is still there after the rollback.

### Build traps

* **Plain `mix compile` cross-compiles rustler NIFs only because `shell.nix` pins
  `CARGO_BUILD_TARGET`.** Without it, `mix deps.compile --force` cross-compiles but a plain
  `mix compile` silently builds an **x86-64** `.so`, surfacing much later as
  `scrub-otp-release.sh: ERROR: Unexpected executable format`. The per-target linker/CC/AR and the
  host-side `CC_x86_64_*` overrides are exported there too — keep them.

* **A deleted build artifact is not rebuilt.** See trap 5. After any `git clean` or gitignore change in
  a NIF-bearing dep: `mix deps.compile <dep> --force`.

* **`mix compile 2>&1 | tail -N` reports `tail`'s exit code.** Redirect to a file and check the build's
  own status, or you will read a failed build as success.

* **Buildroot does not re-extract on a changed `CUSTOM_TARBALL_LOCATION`**, and a `SITE_METHOD = local`
  package does not rebuild unless its `<PKG>_VERSION` is bumped. Symptom: you ship an image without the
  files you just added. Fix: bump the version, or `make <pkg>-dirclean` in the container.

* **Out-of-tree kernel modules do not rebuild on a kernel bump** — `make aic8800-dirclean` and friends.
  Symptom: modules only present under the *old* `lib/modules/<version>/`.

* **Never run the Buildroot container as root**, and never run two builds at once. Root-owned
  `build/`/`host/`/`images/` in the shared Docker volume produces `fixdep: error opening file` and
  `ar: … No such file` across unrelated subsystems on a clean tree. Recovery: `chown -R 1000:100`.

---

## 3. The NPU stack (QNN via onnxruntime via ortex)

### What actually makes it work

ONNX Runtime 1.28 + `onnxruntime_qnn` 2.4.0 is the **plugin EP** model. Appending `"QNN"` by name fails
(`QNN execution provider is not supported in this build`). It must be registered with the environment
(`RegisterExecutionProviderLibrary`) and selected with the V2 device API (`with_devices`). Our ortex
fork does this; you should not need to touch it.

Seven things are each individually load-bearing. Miss any one and you get a session that reports
success and silently runs on the CPU at ~1/20th the speed:

1. **QDQ-quantized model.** A float32 export loads and runs; QNN claims no nodes and it lands on the
   ARM cores with no error. Qualcomm AI Hub QDQ exports work.
2. **Matching QNN version.** The QAIRT 2.42 runtime in `/usr/lib` cannot serve this EP
   (`Unable to find a valid interface for /usr/lib/libQnnHtp.so`). The QNN 2.4.0 set from the
   `onnxruntime_qnn` wheel does. Currently hand-placed at `/root/qnnlibs`.
3. **`libQnnHtpPrepare.so`** (85 MB) — required for on-device graph compilation. With it, first-run
   graph prepare is ~36 ms for yolo11s and no host pre-compilation is needed.
4. **The V68 skel must match too**, or the session fails with `QNN_DEVICE_ERROR_INVALID_CONFIG`.
5. **`DSP_LIBRARY_PATH` / `ADSP_LIBRARY_PATH` are `;`-separated and order-sensitive.** The matching
   skel directory must come first: `"/root/qnnlibs;/usr/lib/dsp"`. Reversed, you get the QAIRT skel and
   a 27x slowdown.
6. **`htp_arch=68`.** Without it the EP logs `Unable to get platform info: Failed to get HTP arch`,
   claims no nodes, and everything runs on CPU.
7. **`intra_op_spinning: false` plus the `performance` governor** — see §4.

From Elixir all of this goes through `Example.Yolo.qnn_opts/1` into `Ortex.load/4`. Read that function
before changing anything.

### Concurrency: the DSP saturates at ~47 inferences/s

| configuration | aggregate | p50 latency |
|---|---|---|
| 1 session | 32.5 fps | 30 ms |
| **2 sessions** | **46.8 fps** | 41 ms |
| 3 sessions | 47.3 fps | 62 ms |
| 4 sessions | 47.5 fps | 83 ms |

This is **pipelining, not parallelism across devices** — there is one NPU. Of a ~33 ms inference, ~21 ms
is serial DSP compute and ~12 ms is ARM-side work (boundary quantize/dequantize, ~7.7 MB of tensor
marshalling, FastRPC dispatch). A second in-flight request overlaps its ARM phase with the first's DSP
phase. **Two sessions is the knee; past it you buy only latency.**

* **Never share one session across concurrent callers.** `Ortex.run` holds a `Mutex<Session>`, so they
  queue: 32.5 fps with latency doubled. Each worker needs its own session.
* `Nx.Serving`'s `partitions: true` does **not** help as `Ortex.Serving` is written — its `init/3`
  captures a single model and `handle_batch/3` uses the partition index only to pick `defn_options`, so
  every partition funnels into that one mutex. Fixing it to hold one model per partition would make the
  abstraction real.
* **`Nx.Batch` cannot help at all**: the AI Hub exports pin batch to 1 and reject `{2,3,640,640}`
  outright. A batched export would also be a separate static QNN graph with its own compile cost.

### Two different models cost the same as two sessions of one

det + pose concurrently: **47.1 inf/s aggregate**, versus 46.9 for two detection sessions, with equal
latency. The DSP does not care which graph an inference belongs to; it is a fungible ~47 inf/s budget
you are splitting. Memory is where they differ (below).

### Loading a model tears down the FastRPC domain — load everything first

Creating a session closes **all** handles on domain 3 and re-creates the process domain:

```
remote_handle64_close: closed module libQnnHtpV68Skel.so … num of open handles: 0
domain_deinit done for domain 3.
remote_session_control Unsigned PD enable 1 request for domain 3
Created user PD on domain 3 … Unsigned:Y
```

**Hypothesis, not proven:** another session invoking during that window touches torn-down state, and
this is what produced several hard board resets with no software failure signature. Every reset happened
in a VM that already had sessions alive when a new one was created; code that loads all models before
starting any inference has never reproduced it.

**Rule regardless: create all QNN sessions up front, never load a model while another session is
mid-invoke.** `Example.Soak` is built this way on purpose.

### Predicting memory and load time

Measured across four models spanning 36–100 MB of weights:

* **Memory: `RSS ≈ 0.92 × (spill_bytes + fill_bytes)`** — 4.1% spread. Both numbers are printed by
  `libQnnHtpPrepare` during graph prepare, so one `qnn-probe` run predicts the deployed footprint
  before you deploy anything.
* **Load time: `≈ 0.09 s per MB of weights`** — 5.1% spread, near-linear. yolo11l-pose took 9.1 s.
* **`RSS/weights` ranges 2.11–3.99 — do not use it.** If file size is all you have, budget 4x.
* **One-time ~238 MB per OS process** for the QNN backend and prepare libraries: on a clean boot the
  first model costs +320 MB where the same model costs +82 MB later.
* **A duplicate session of the same model is ~28 MB** (weights mapped once); a **distinct model is
  79–106 MB**. So det+pose ≈ 185 MB against det+det ≈ 107 MB, for identical throughput.

VTCM being only 2 MB is why these models spill so hard — `spill_bytes` 42 MB / `fill_bytes` 49 MB for
yolo11s. Forcing `vtcm_mb=1` doubles the spill and costs ~40% throughput, which is a useful confirmation
that **VTCM residency dominates**: a model tiled to fit 2 MB will beat a larger one by more than its FLOP
count suggests.

### Dead ends, so nobody re-investigates them

* **Signed vs unsigned PD is not a problem.** `/dev/fastrpc-cdsp-secure` appears in the fd list even on
  a pure-CPU run — it is opened when `libQnnHtp.so` loads. It was never evidence about execution.
* **`QnnHtpV68Skel` absent from `/proc/self/maps` proves nothing** — it is a Hexagon ELF that runs on
  the DSP and never maps into the ARM process.
* **`Some nodes were not assigned to the preferred execution providers`** is generic ORT boilerplate.
* **Python is not an escape hatch.** `onnxruntime` + `onnxruntime_qnn` from the wheels imports and runs,
  but `register_execution_provider_library` succeeds and then the EP never appears in
  `sess.get_providers()` and no `/dev/fastrpc-*` is opened. 887 ms/iter, i.e. CPU. The Elixir/Rust path
  is ahead of the vendor reference.

---

## 4. The spin-wait / governor interaction

onnxruntime's intra-op pool descends from Eigen's non-blocking pool, built for CPU graphs of hundreds of
few-microsecond kernels where a futex wake (~5–50 µs) costs more than the kernel computes. So its
workers **spin before parking**. When the whole graph is one offloaded EP node taking ~33 ms, they spin
through the entire inference.

Cost of leaving it on: ~6 ARM cores pinned (539% of wall), cpu0 at 89 °C, cpufreq cooling saturated at
9/9, and throughput decaying 24 → 20.6 fps over 20 minutes as the package throttled — heat produced by
threads doing nothing, throttling the NPU that was doing the work.

**But turning it off alone makes things worse.** The spinning doubles as an accidental cpufreq governor:

```
spin=ON  schedutil     27.9 fps   539% cpu   1958/1900/806 MHz   71.6 °C
spin=OFF schedutil     20.6 fps    52% cpu    691/691/806 MHz    60.6 °C   <- halved
spin=OFF performance   29.2 fps    27% cpu   1958/2400/2707 MHz  62.2 °C   <- shipped
spin=OFF perf+pmqos=0  30.2 fps    37% cpu   1958/2400/2707 MHz  64.9 °C
```

Both changes are needed together. PM QoS on `/dev/cpu_dma_latency` does nothing on its own (17.9 fps) —
deep idle was never the problem, frequency was. `intra_threads` is noise under `performance` (0/2/4/8
all land 27–30 fps), so it stays at onnxruntime's default.

Result: same throughput for a twentieth of the CPU. Over 7.5 hours: **28.60 fps mean, drift −0.01 fps/h,
777,441 inferences, zero errors, zero throttled intervals**, cpu0 71.2 °C, against 21.29 fps *decaying
at −6.55 fps/h* before.

Defaults now: `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y` in the kernel (so it applies as each policy
comes online, no userspace race), and `intra_op_spinning: false` in `Example.Yolo.qnn_opts/1`.
`Example.Soak` also sets the governor and restores it on stop — which **invalidates any benchmark run
after `Soak.disable/0`**; set it explicitly when measuring.

---

## 5. Nx, EXLA and ortex on this board

### EXLA works, cross-compiled, and is worth having

One knob, in `example/mix.exs` (Mix evaluates it before compiling deps):

```elixir
System.put_env("XLA_TARGET_PLATFORM", "aarch64-linux-gnu")
System.put_env("XLA_TARGET", "cpu")
```

`xla` then fetches the aarch64 archive; EXLA's own Makefile already handles `CROSSCOMPILE` and builds
with `$(CXX)`. Verified before committing to it: `libxla_extension.so` is **392 MB** on disk (~56 MB
compressed, firmware 165 → 240 MB), max symbol requirement `GLIBC_2.27`, and `libstdc++.so.6.0.34` +
`libgcc_s.so.1` are already in `/lib`.

Required config, or `defn` silently runs through Nx's interpreter and is *slower* than eager:

```elixir
config :nx, default_backend: EXLA.Backend
config :nx, default_defn_options: [compiler: EXLA]
config :exla, clients: [host: [platform: :host]], default_client: :host
```

### BinaryBackend is unusable for image-sized tensors

| op on an 8400×84 tensor | BinaryBackend | EXLA eager | fused `defn` |
|---|---|---|---|
| squeeze + transpose | 246 ms | 2.9 ms | |
| reduce_max over 80 | 265 ms | 0.8 ms | |
| argmax over 80 | 289 ms | 1.7 ms | |
| all three | ~800 ms | ~5.4 ms | **2.8 ms** |

The naive Nx letterbox preprocess was **9.0 s** per 640×640 frame on BinaryBackend. Any Nx elementwise
or transpose work on image-sized data must have its backend checked — see trap 1.

### `EXLA.Backend` eager is not enough; fuse into `defn`

Eager EXLA runs each op as its own XLA computation with a host round-trip. Whole preprocess, median of
7: **70 ms** pure-binary fallback, **65 ms** op-by-op EXLA, **52 ms** fused into a `defn`. The gain from
EXLA only materialises when you fuse.

### Keep shapes static, on purpose

* **`defn` options are compile-time constants.** Pass anything that varies at runtime as a **tensor**,
  or XLA compiles a fresh kernel per distinct value (e.g. one per image aspect ratio).
* **Variable-shape gathers recompile.** The confidence threshold used to run on the BEAM and gather a
  varying number of rows. Replacing it with `Nx.top_k(k)` inside the kernel makes the shape fixed:
  whole head including top_k is **3 ms**, moving k rows measures **0 ms**, and decode fell 17 → 11 ms
  (detection) and 13 → 9 ms (pose).
* **Keep NMS on the BEAM.** Its shape depends on the survivor count, so a kernel would recompile per
  frame — far more than the few ms it costs on a few hundred rows.

The rule is not "jit everything", it is **"jit everything whose shape is static, and keep the shape
static on purpose"**.

### The GPU is not available for tensor math

XLA's GPU backend is CUDA/ROCm only; there is no Adreno target, so EXLA cannot use the GPU at all.
Reaching it would mean OpenCL via rusticl (not built) or hand-written Vulkan/GL kernels plus a non-XLA
path. Not worth it — after the fixes above, decode is ~10 ms and the remaining CPU cost is JPEG decode
(~29–80 ms, already C).

### ortex specifics

Dependency (our fork; **the repo is private**, so an outside clone fails on auth):

```elixir
@ortex_ref "313c46777fc4656942fe94e0e57d7be08b7af738"
{:ortex, git: "git@github.com:monoflow-ayvu/ortex.git", ref: @ortex_ref, override: true}
```

* `Ortex.run` returns an `Ortex.Backend` tensor. Transfer it to the default backend (trap 1).
* Inputs are pulled across with `Nx.backend_transfer`, which deletes the source (trap 4). A reusable
  prepared frame must end with `Nx.backend_copy(Nx.BinaryBackend)` — that also removed a per-inference
  device round-trip, 77 ms → 32 ms.
* `Inspect` for `Ortex.Model` was broken on Elixir 1.19 (protocol impls now return `{doc, opts}`, which
  `Inspect.Algebra.concat/2` rejects) — fixed in the fork; use `to_doc/2` if you touch it again.

---

## 6. Measurement discipline

Almost every wrong conclusion in this project came from one of these. They are listed in the order they
bit us.

1. **Always discard the first call.** XLA compiles kernels (200 ms – 1.5 s) and the HTP compiles graphs
   (~36 ms – 9 s). The first pose decode measured 218 ms against a steady state of 13 ms.
2. **State whether a number is model throughput or pipeline throughput.** `bench/2` times only
   `Ortex.run`. That is 29–48 fps; end-to-end from a JPEG is ~11–20 fps. Reporting the former as "fps"
   hid a 1143 ms decode for days.
3. **CPU%-of-wall does not indicate whether an accelerator is working.** The HTP path still charged
   595% of wall because the thread pool spin-waits. Spin-wait and compute are indistinguishable in
   `/proc/self/stat`. This produced a completely wrong "the NPU is not doing the compute" retraction.
4. **The trustworthy accelerator test is falsification.** Hide the Hexagon skel
   (`ADSP_LIBRARY_PATH=/nonexistent`) and re-run: if throughput is unchanged, it was never on the NPU.
   With the skel hidden the identical config collapses to CPU speed *while still reporting
   `session OK`*.
5. **A CPU baseline is hard to obtain and easy to fake.** ORT auto-selects a registered plugin EP, so a
   session requesting *no* EP still runs on the NPU. `ORTEX_QNN_SKIP=1` was not a CPU baseline whenever
   the DSP environment was configured — which made several A/B tests compare the NPU against itself and
   "prove" there was no speedup. A real baseline needs the DSP unreachable, and it must be the *first*
   QNN session in the process because the backend/skel are resolved once and cached.
6. **Thermal sensors quantise to ~0.4–0.8 °C.** Short-window regressions on them lie: a "+6 °C/h" trend
   over eight samples that were in fact flat. Look at the raw values.
7. **`erl_eval` is ~50x slower than compiled code for bit-syntax comprehensions.** Timing a binary
   comprehension in an SSH one-liner reported 5.6 s for something that takes ~95 ms in a module.
8. **Cooling-device states do not cover the NPU** (§1). "0 throttled intervals" is not proof.
9. **`Soak.disable/0` restores the previous governor**, silently invalidating benchmarks run afterwards
   (61 ms instead of 35 ms, purely from `schedutil` coming back).
10. **Absence of evidence on the ARM side is not evidence about the DSP.** No crash dump, no OOM, no
    segfault and `wdt_last_boot=power_on` was read as "must be power" when a fault inside the DSP domain
    produces exactly that signature. The user's 5.5 W measurement disproved it.

---

## 7. Diagnostics playbook

**Did the NPU actually take the graph?**

```elixir
Example.Yolo.load(trace_path: "/tmp/t.log", "env.RUST_LOG": "trace")
# Node(s) placed on [QNN]. Number of nodes: 1
# Node(s) placed on [CPUExecutionProvider]. Number of nodes: 2
```

`RUST_LOG=trace` is required: onnxruntime logs the placement report at VERBOSE, `ort` maps that onto
tracing's TRACE level, and the default filter is `debug`. Raising the *session* log severity does not
help. Expect ~8 MB of trace per session. Tracing can be enabled from any session (it used to latch on
the first one, so a running soak made the node undiagnosable).

**Standalone, outside the VM:** `/root/qnn-probe <model.onnx>` with `ORTEX_QNN_*` env vars. Prints
device enumeration before/after registration, the placement attempt, spill/fill bytes, wall-vs-CPU
timing, and which QNN libs got mapped. `ORTEX_QNN_SKIP=1`, `ORTEX_ITERS`, `ORTEX_QNN_OPTS` are the
useful knobs.

**A slot that will not boot:** `/root` is shared, so read `/root/erl_crash.dump` after the rollback —
the `Slogan:` line names the cause exactly (that is how the missing-NIF crash was found).

**Was it a watchdog reset?**

```elixir
{:ok, h} = Nerves.Runtime.Heart.status()
h.wdt_last_boot         # :power_on means NOT a watchdog reset
h.heartbeat_time_left   # heart petting normally?
```

**Who is burning CPU?** Sample `/proc/<beam>/task/*/stat` and group by `comm`. Note that
onnxruntime's pool threads **inherit the BEAM dirty-IO scheduler's thread name** (Linux pthreads keep
the parent's `comm` unless they set their own), so 7 consecutive tids called `erts_dios_2` are really
ORT workers. That is how the spin-wait was found.

**Known-harmless log noise:** venus `failed to reset venus core` and the `arm-smmu … Unhandled context
fault` at ~5 s (video codec, unresolved), audio topology `tplg firmware loading … failed -2`,
`aic_load_fw … failed with error -1`, `Cannot find any crtc or sizes` (pre-HPD transient),
`Tainted: W` inherited from an early r8169 WARN, `nerves_heart: can't open '/dev/watchdog0'` under QEMU
only, and FastRPC's `Couldn't find file beam.smp.farf`.

---

## 8. Measured performance reference (yolo11s QDQ, 640×640)

| stage | cost |
|---|---|
| JPEG decode (`StbImage.read_file`) | 80 ms (810×1080), 44 ms (1280×720) |
| preprocess: resize + letterbox + planar f32 | 52–73 ms |
| inference on the HTP | 32–37 ms |
| inference on the ARM cores | ~865 ms |
| decode + NMS, detection | 11 ms |
| decode + NMS, pose | 9 ms |

* **Model throughput:** 29 fps single session, **47 fps with two** (hard DSP ceiling).
* **End-to-end, one model, full decode:** ~20 fps from a prepared frame, ~11.5 fps from a fresh JPEG.
* **Two different models, both fully decoded:** ~22 fps each, 44 fps aggregate, 0 errors.
* Larger models: yolo11m 59 ms/inference, yolo11l-pose 67 ms.
* **Pose decode is *cheaper* than detection decode** (9 vs 11 ms), which surprised us. Detection reduces
  over 80 class scores for all 8400 anchors twice (`reduce_max` + `argmax`); pose has a single person
  score and touches its 17 keypoints only for anchors that survive thresholding. More output channels
  does not mean more decode work — what matters is how much of the wide tensor you reduce over.

Preprocessing costs more than inference. For a camera pipeline, feed frames that are already 640×640
and reuse one prepared buffer.

---

## 9. What is on the device

```
/root/qnnlibs/          QNN 2.4.0 set from the onnxruntime_qnn wheel — libQnnHtp.so,
                        libQnnHtpPrepare.so (85 MB), libQnnHtpV68Stub/Skel.so, libQnnSystem.so
/root/det/              yolo11s detection, AI Hub QDQ  (model.onnx + model.data)
/root/pose/             yolo11s-pose
/root/det_m/            yolo11m detection
/root/pose_l/           yolo11l-pose
/root/qnn-probe         standalone Rust ort probe
/root/py/               onnxruntime 1.28 + onnxruntime_qnn python site-packages (49 MB)
/root/bus.jpg, zidane.jpg   the canonical Ultralytics test images
/data/soak*.csv         soak results (see Example.Soak.summary/1)
```

**`/root/qnnlibs` is hand-placed and not in the firmware.** Shipping it means vendoring ~107 MB into
`blobs/onnxruntime-qnn/usr/lib/onnxruntime-qnn/` under a prefix that does not collide with
qairt-runtime's `/usr/lib/libQnnHtp.so`. `Example.Yolo.qnn_opts/1` already looks in
`/usr/lib/onnxruntime-qnn` first and falls back to `/root/qnnlibs`. Until that is done, **a freshly
flashed board has no working NPU stack.**

---

## 10. Open questions

* **Ship `/root/qnnlibs` in the image** (§9) — the biggest gap between this working and being
  reproducible. Blocked on the proprietary-blob redistribution decision.
* **Prove or kill the FastRPC-domain-teardown hypothesis** (§3): from a fresh boot, start one worker
  looping, then create a second session while it runs, and see whether the reset reproduces.
* **Make `Ortex.Serving` hold one model per partition** so `Nx.Serving`'s `partitions: true` is real.
* **Add an NSP-above-90 °C derived column** to the soak, since that is the only visible throttle signal.
* **Venus (`-110`) and the audio topology blob** remain unfixed; both are known-harmless log noise today.
* A full `make clean` rebuild before any release — stale modules from earlier kernel versions have been
  observed in the tree.
