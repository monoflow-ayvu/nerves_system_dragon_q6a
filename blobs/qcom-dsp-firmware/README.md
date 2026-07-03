# qcom-dsp-firmware blobs (Phase-0 harvest)

The kernel's remoteproc loads these signed Hexagon DSP images by the
`firmware-name` paths in `qcs6490-radxa-dragon-q6a.dts`. They are **not**
redistributable in any public package, so they must be harvested from a
stock RadxaOS install running on the actual board.

## Required paths (drop the files here, keeping this layout)

```
blobs/qcom-dsp-firmware/lib/firmware/qcom/qcs6490/cdsp.mbn
blobs/qcom-dsp-firmware/lib/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn
```

(`cdsp.mbn` is the one the acceptance test needs; `adsp.mbn` is for audio
DSP later.)

## Harvest procedure (on a stock RadxaOS boot, Phase 0)

1. `apt install fastrpc libcdsprpc1 fastrpc-test` and confirm
   `fastrpc_test -a v68` passes.
2. Copy the firmware the running kernel actually loaded:
   ```sh
   cp -a /lib/firmware/qcom/qcs6490/cdsp.mbn .
   cp -a /lib/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn .
   ```
   (Check `dmesg | grep -i cdsp` for the exact path if it differs.)
3. Record the version string (`strings cdsp.mbn | grep -i KODIAK`) and make
   sure it matches the `fastrpc_shell_unsigned_3` shipped by
   `qcom-dsp-shell` (CDSP.HT.2.5.c4-00004-KODIAK-1). If they differ, either
   re-pin the shell in `package/qcom-dsp-shell/qcom-dsp-shell.mk` to match
   this cdsp.mbn, or use the matching pair from Olof's validated combo.
4. Drop the files into the paths above and add sha256sums to `SHA256SUMS`.

Until then the build installs no firmware (fine for QEMU; the CDSP will not
come up on hardware).
