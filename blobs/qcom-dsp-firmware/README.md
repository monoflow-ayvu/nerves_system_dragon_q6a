# qcom-dsp-firmware blobs (vendored from upstream linux-firmware)

Signed Qualcomm firmware for the Radxa Dragon Q6A, vendored from
**upstream linux-firmware** (`main`, July 2026 — Radxa contributed the
board-specific DSP set upstream). All files are marked
*"Licence: Redistributable"* in linux-firmware's WHENCE; see
`LICENSE.qcom` and `NOTICE.qcom` here.

The kernel loads these by the `firmware-name` paths in
`qcs6490-radxa-dragon-q6a.dts` (or the driver's built-in path for
GPU/Venus).

## Layout (mirrors upstream linux-firmware, symlinks included)

```
lib/firmware/qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn    CDSP.HT.2.5.c4-00004-KODIAK-1 (remoteproc_cdsp)
lib/firmware/qcom/qcs6490/radxa/dragon-q6a/cdspr.jsn
lib/firmware/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn    ADSP.HT.5.5.c9-00028-KODIAK-2 (remoteproc_adsp)
lib/firmware/qcom/qcs6490/radxa/dragon-q6a/adspr.jsn
lib/firmware/qcom/qcs6490/radxa/dragon-q6a/adspua.jsn
lib/firmware/qcom/qcm6490/{cdsp,adsp}.mbn              generic Kodiak fallbacks
lib/firmware/qcom/qcs6490/{cdsp,adsp}.mbn              -> ../qcm6490/* (upstream symlinks)
lib/firmware/qcom/qcm6490/a660_zap.mbn                 Adreno 643 zap shader
lib/firmware/qcom/qcs6490/a660_zap.mbn                 -> ../qcm6490/a660_zap.mbn (DTS zap path)
lib/firmware/qcom/a660_sqe.fw, a660_gmu.bin            Adreno 643 SQE/GMU (drm/msm)
lib/firmware/qcom/vpu/vpu20_p4.mbn                     Venus video firmware
lib/firmware/qcom/vpu-2.0/venus.mbn                    -> ../vpu/vpu20_p4.mbn (sc7280 venus path)
lib/firmware/qcom/qcm6490/qupv3fw.elf                  GENI SE (QUP) firmware
```

## Version matching (frozen tuple, see GOAL.md)

The board `cdsp.mbn` is **CDSP.HT.2.5.c4-00004-KODIAK-1**, which matches
the `fastrpc_shell_unsigned_3` pinned in
`package/qcom-dsp-shell/qcom-dsp-shell.mk`. Verify after any refresh:

```sh
strings lib/firmware/qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn | grep KODIAK
```

If the versions diverge, FASTRPC_IOCTL_INIT_CREATE fails with 0x80000600 —
re-pin `qcom-dsp-shell` to the matching directory.

## Refreshing

```sh
BASE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main
curl -fLO $BASE/qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn   # etc.
(cd lib/firmware && find . -type f -exec sha256sum {} \;) > SHA256SUMS
```

Verify with `(cd lib/firmware && sha256sum -c SHA256SUMS)` from this dir's
parent of `lib/firmware` (paths in SHA256SUMS are relative to
`lib/firmware`).
