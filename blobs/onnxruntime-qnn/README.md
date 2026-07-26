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

## The QNN backend comes from qairt-runtime, deliberately

`onnxruntime_qnn-2.4.0` also bundles its own QNN backend
(`libQnnHtp.so`, `libQnnSystem.so`, `libQnnHtpV68Stub.so`,
`libQnnHtpV68Skel.so`, plus V69–V81 sets and an 89 MB
`libQnnHtpPrepare.so`). We do **not** vendor those: `blobs/qairt-runtime`
already ships a QAIRT 2.42.0.251225 set that is validated on this board
(`fastrpc_test -a v68` 3/3, `qnn-platform-validator` unit test Passed), and
installing a second set would collide on `/usr/lib/libQnnHtp.so` and on the
`libQnnHtpV68Skel.so` name inside `DSP_LIBRARY_PATH`.

Point the EP at the existing backend:

```elixir
Ortex.load(path, [{:qnn, backend_path: "/usr/lib/libQnnHtp.so"}])
```

**Version-skew risk, accepted knowingly:** ORT 1.28's QNN EP was built against
the QNN version bundled in its own wheel, not against QAIRT 2.42. If the EP
rejects the backend at session creation, the fallback is to vendor the wheel's
QNN set under a separate prefix (e.g. `/usr/lib/onnxruntime/`) and set
`backend_path` plus a per-process `DSP_LIBRARY_PATH` accordingly. Adds ~45 MB.

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
