# onnxruntime-qnn blobs

ONNX Runtime 1.28.0 C library + the Qualcomm QNN execution provider, for
HTP/NPU inference from Rust (`ort`) and Elixir (`ortex`).

## Why no source build

The QNN EP is a **shared provider**, not a compiled-in one. `ort`'s
`QNNExecutionProvider::register()` calls
`SessionOptionsAppendExecutionProvider(session, "QNN", opts)`
(pykeio/ort `src/ep/qnn.rs`), and ONNX Runtime then `dlopen()`s
`libonnxruntime_providers_qnn.so` at session-creation time. So a **stock**
`libonnxruntime.so` works and there is no need to build ONNX Runtime from
source against the QAIRT SDK — which matters, because Qualcomm does not
officially support the QNN SDK on aarch64 Linux.

## Provenance

Extracted from the same upstream wheels that `radxa-q6a-yocto` validated on
this SoC (`meta-q6a-nerveshub/recipes-ml/python3-onnxruntime-qnn`). We take the
`.so` files only — this image has no Python.

| File | Source wheel | Size |
|---|---|---|
| `usr/lib/libonnxruntime.so.1.28.0` | `onnxruntime-1.28.0-cp314-cp314-manylinux_2_27_aarch64.manylinux_2_28_aarch64.whl` → `onnxruntime/capi/` | 20.7 MB |
| `usr/lib/libonnxruntime_providers_shared.so` | same | 0.2 MB |
| `usr/lib/libonnxruntime_providers_qnn.so` | `onnxruntime_qnn-2.4.0-cp314-cp314-manylinux_2_34_aarch64.whl` → `onnxruntime_qnn/` | 3.4 MB |

`usr/lib/libonnxruntime.so` is a symlink to the versioned file, which is what
`ort`'s `load-dynamic` / `ORT_DYLIB_PATH` expects.

`manylinux_2_34` needs glibc >= 2.34; this system is on **2.43**.

## The QNN backend: vendored in `usr/lib/onnxruntime-qnn/`, not qairt-runtime

`onnxruntime_qnn-2.4.0` bundles its own QNN backend (`libQnnHtp.so`,
`libQnnSystem.so`, `libQnnHtpV68Stub.so`, `libQnnHtpV68Skel.so`, plus an
89 MB `libQnnHtpPrepare.so`). That set is vendored under
`usr/lib/onnxruntime-qnn/` (see below) because `blobs/qairt-runtime`
ships a **different version** (QAIRT 2.42.0.251225) of the same filenames
under `/usr/lib` and `/usr/lib/dsp` — the two stacks cannot share a
prefix. The QAIRT 2.42 set serves `qnn-platform-validator`; the vendored
2.4.0 set serves the ORT EP. The EP must be pointed at the subdir:

```elixir
Ortex.load(path, [{:qnn, backend_path: "/usr/lib/onnxruntime-qnn/libQnnHtp.so"}])
```

**Version-skew note:** ORT 1.28's QNN EP is built against the QNN version
bundled in its own wheel, which is why the wheel's set is used instead of
QAIRT 2.42 (`Unable to find a valid interface for /usr/lib/libQnnHtp.so`).

## On-device graph compilation is NOT available

`libQnnHtpPrepare.so` (89 MB) is not vendored, so the HTP cannot compile a
graph on the device. Models must be either
- pre-compiled to a QNN context binary on a host with the full SDK, and loaded
  via the EP's `qnn_context_cache_enable` / EPContext path, or
- run with the EP falling back for unsupported subgraphs (slow, partly on CPU).

Add `libQnnHtpPrepare.so` from `onnxruntime_qnn-2.4.0` if on-device prepare is
needed.

## Redistribution

`libonnxruntime*` is MIT. `libonnxruntime_providers_qnn.so` is Qualcomm
proprietary — `ONNXRUNTIME_QNN_REDISTRIBUTE = NO`. Note `blobs` is in
`package_files()` (`mix.exs`), so publishing this repo to Hex or a GitHub
release would redistribute it. Same open question as `blobs/qairt-runtime`.

## `usr/lib/onnxruntime-qnn/` — the QNN 2.4.0 runtime the EP actually needs

Five files, 105 MB, from the same `onnxruntime_qnn` 2.4.0 aarch64 wheel as
`libonnxruntime_providers_qnn.so`:

| file | size | why |
|---|---|---|
| `libQnnHtpPrepare.so` | 85 MB | on-device graph compilation. Without it the session fails to commit: `Node ... OpType:Conv with domain:com.ms.internal.nhwc was inserted using the NHWC format as requested by QNN, but was not selected by that EP` |
| `libQnnHtpV68Skel.so` | 10 MB | the Hexagon-side code. A mismatched version gives `QNN_DEVICE_ERROR_INVALID_CONFIG` |
| `libQnnSystem.so` | 5.3 MB | |
| `libQnnHtp.so` | 4.3 MB | the backend the EP loads (`backend_path`) |
| `libQnnHtpV68Stub.so` | 0.5 MB | ARM-side stub for the skel |

Checksums (sha256, first 16 hex): `53cc30587bb0f0de` libQnnHtp, `fce94a061b8152b1`
libQnnHtpPrepare, `722426cbc5c74a2f` libQnnHtpV68Skel, `0df22195ab471374`
libQnnHtpV68Stub, `ed5442fec388a4ad` libQnnSystem. Verified byte-identical to the
set that was proven working on the board.

### Why a subdirectory and not `/usr/lib`

`qairt-runtime` already installs **QAIRT 2.42** versions of `libQnnHtp.so`,
`libQnnSystem.so`, `libQnnHtpV68Stub.so` into `/usr/lib`, and its V68 skel into
`/usr/lib/dsp`. Those serve `qnn-platform-validator`. They **cannot** serve
onnxruntime's QNN EP — it fails with `Unable to find a valid interface for
/usr/lib/libQnnHtp.so`. The two stacks need different versions of the same
filenames, so this set lives in its own directory and neither overwrites the other.

### Flat, not `dsp/`

All five sit in one directory on purpose. `Example.Yolo.qnn_opts/1` points both
`backend_path` and `DSP_LIBRARY_PATH` at this directory, which is the layout proven
to work; it only looks for a `dsp/` subdirectory if one exists.

### Do not change the global `DSP_LIBRARY_PATH`

`rootfs_overlay/etc/erlinit.config` sets it to `/usr/lib/dsp` — the QAIRT skel — and
it must stay that way, or `qnn-platform-validator` breaks. Consumers of the ORT QNN
EP override it per session (ortex's `env.*` opts), which is the only way to give the
two stacks different skels in one system.

### Git LFS

These are tracked via LFS (`.gitattributes`). A clone without `git lfs install`
gets pointer files, and the Buildroot package will then install nothing and print
`*** onnxruntime-qnn: no blobs in blobs/onnxruntime-qnn/usr; nothing installed.`
