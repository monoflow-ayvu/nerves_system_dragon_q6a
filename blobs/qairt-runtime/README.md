# qairt-runtime blobs (Qualcomm QAIRT/QNN SDK)

Populated from **QAIRT SDK 2.42.0.251225**
(`https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.42.0.251225/v2.42.0.251225.zip`),
`aarch64-oe-linux-gcc11.2` variant (glibc; max requirement GLIBC_2.34 —
compatible with the Nerves 15.3.0 toolchain rootfs). Enabled via
`BR2_PACKAGE_QAIRT_RUNTIME=y` in `nerves_defconfig`.

Proprietary — local use only, never redistribute this tree
(`QAIRT_RUNTIME_REDISTRIBUTE = NO`).

## Manifest (sha256)

```
6a04a4b8e276b863eb1ea8550f6855a3f8345412c5548f5679d26d7c2609b02a  usr/lib/libQnnHtp.so
1436f5337f6d469cb6aca1095fc7426ab1ac61d030c4a39b2cdf013fe17d9ec4  usr/lib/libQnnHtpV68Stub.so
9c2692c5cbc5d062beede749480cf3448fa9aa0267dfcb94933ad63078cf356d  usr/lib/libQnnSystem.so
2cf8b6662cd9c98049c6ac0285d83c4b6966e6a1c9abb00aa843cb8e7e706b3c  usr/lib/dsp/libQnnHtpV68Skel.so
8d8d1602a921256685410e9b3454dd4b29d5eb4b74effe75bb21b4a0313dc5c0  usr/bin/qnn-platform-validator
```

SDK source paths:

- `lib/aarch64-oe-linux-gcc11.2/{libQnnHtp,libQnnHtpV68Stub,libQnnSystem}.so` → `usr/lib/`
- `lib/hexagon-v68/unsigned/libQnnHtpV68Skel.so` → `usr/lib/dsp/` (loaded on
  the CDSP via `DSP_LIBRARY_PATH`)
- `bin/aarch64-oe-linux-gcc11.2/qnn-platform-validator` → `usr/bin/` (optional
  bench diagnostic)

`libQnnHtpPrepare.so` is intentionally **omitted**: the Elixir bindings
(`hexagon_tpu`) load pre-compiled context binaries only, which never invoke
on-device graph prepare. Drop it in from the same SDK dir if that changes.

Runtime deps already in the image: `libcdsprpc.so` (qcom-fastrpc),
`libstdc++/libatomic/libgcc_s` (toolchain). Not needed for the
`fastrpc_test -a v68` acceptance test.
