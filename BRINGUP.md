# BRINGUP.md - Dragon Q6A bench playbook

The log of what to do the day the board is on the desk. Everything here is
blocked on hardware; the repo itself is validated in QEMU (see
`test/qemu-smoke.sh`). Fill in the "Observed" blanks as you go - they feed
the frozen tuple in `GOAL.md`.

## 0. Serial console first

Debug UART, **`ttyMSM0`, 115200 8N1**, 3.3 V. Confirm you see the XBL/UEFI
log before touching anything. The board DTS sets
`stdout-path = "serial0:115200n8"` (`serial0 = &uart5`).

## 1. EDL recovery (practice until boring)

Bottom of the boot chain is signed vendor firmware in QSPI NOR; a bad ESP
is recovered via **EDL**, not reflashing SD.

- **Enter EDL:** hold the button next to the headphone jack while powering
  on, connected to the host via the **USB 3 (Type-A) port** with a
  **Type-A ↔ Type-A** cable.
- **Tool:** [`edl-ng`](https://github.com/strongtz/edl-ng) (v1.4.1 used by
  the interfacinglinux write-up).
  ```sh
  wget https://github.com/strongtz/edl-ng/releases/download/v1.4.1/edl-ng-linux-x64.zip
  unzip edl-ng-linux-x64.zip
  # From within Radxa's firmware snapshot dir:
  sudo ./edl-ng --memory spinor --loader prog_firehose_ddr.elf rawprogram rawprogram0.xml patch0.xml
  ```
- Firmware snapshot + flashing docs: https://docs.radxa.com/en/dragon/q6a
  (firmware/EDL sections). Armbian notes the **latest UEFI firmware is
  required**.
- **Observed UEFI version string** (`QC_IMAGE_VERSION_STRING=BOOT...KODIAK...`
  from the boot log): __________ → record in `GOAL.md`.

## 2. Phase-0 NPU sanity check (blobs already vendored)

The DSP firmware is now vendored in `blobs/qcom-dsp-firmware/` from upstream
linux-firmware (board `cdsp.mbn` = `CDSP.HT.2.5.c4-00004-KODIAK-1`, matching
the pinned shell) - no harvest is required. A stock RadxaOS boot is still
the fastest way to cross-check the known-good tuple if anything misbehaves:

```sh
apt install fastrpc libcdsprpc1 fastrpc-test
# confirm it passes:
LD_LIBRARY_PATH=/usr/lib/fastrpc_test DSP_LIBRARY_PATH=/usr/share/fastrpc_test/v68 fastrpc_test -a v68
# harvest:
cp -a /lib/firmware/qcom/qcs6490/cdsp.mbn ~/harvest/
strings /lib/firmware/qcom/qcs6490/cdsp.mbn | grep -i KODIAK   # version string
dmesg | grep -iE "cdsp|fastrpc|remoteproc"                     # save this
cp /sys/firmware/fdt ~/harvest/stock.dtb                       # DTB in use
```

- **Observed cdsp.mbn version string:** __________
- If it matches `CDSP.HT.2.5.c4-00004-KODIAK-1`, the `qcom-dsp-shell` pin is
  already correct. If not, re-pin the shell in
  `package/qcom-dsp-shell/qcom-dsp-shell.mk` to the matching version, or use
  Olof's validated combo (generic upstream `qcm6490/cdsp.mbn` + matching
  RB3gen2 shell at the same string).
- The vendored blobs already carry the matching version; only revisit
  `blobs/qcom-dsp-firmware/` if the observed stock version differs.

Also confirm which device nodes exist and which domain the test uses:
```sh
ls -l /dev/fastrpc-*        # expect -adsp, -cdsp, maybe -cdsp-secure
```
CDSP = domain 3 = `-a v68`.

## 3. First flash of our image

```sh
cd example
MIX_TARGET=dragon_q6a mix firmware
MIX_TARGET=dragon_q6a mix firmware.burn   # to microSD
```

Insert SD, set the UEFI boot order to the SD, power on with serial attached.
Expect: GRUB "Booting slot A" → kernel 6.18 → IEx on `ttyMSM0`.

- If UEFI won't load `\EFI\BOOT\BOOTAA64.EFI` from removable media: check
  Secure Boot is off; if still no go, fall back to keeping Radxa's embloader
  on the ESP and generating BLS entries (documented fallback, not yet
  implemented).
- If the kernel hangs early: add `earlycon` to the cmdline in `grub.cfg`.

## 4. Acceptance test (§9 of the task doc)

On a freshly flashed image, over serial, no manual setup:

1. Reaches IEx (Nerves runtime up). Already proven in QEMU.
2. `dmesg` shows `remoteproc ... cdsp.mbn ... remote processor cdsp is now up`
   and **no** `no reserved DMA memory for FASTRPC`.
3. `/dev/fastrpc-cdsp` exists 0666; `cdsprpcd` running (`Example.npu_status()`).
4. `fastrpc_test -a v68` → all PASS (hap_example, multithreading, calculator).
5. Stretch: `qnn-platform-validator` reports HTP usable (needs `qairt-runtime`).
6. A/B: `Nerves.Runtime.revert` flow works.

Invocation baked into the image env (`/etc/erlinit.config`,
`/etc/profile.d/qcom-npu-env.sh`): `DSP_LIBRARY_PATH=/usr/lib/dsp`. From a
shell: `fastrpc_test -a v68`.

## Observed versions (fill in)

| Component | Planned | Observed on bench |
| --- | --- | --- |
| UEFI firmware | latest Radxa snapshot | |
| Kernel | 6.18.2 (radxa/kernel 559f4f92) | |
| cdsp.mbn version string | CDSP.HT.2.5.c4-00004-KODIAK-1 | |
| fastrpc_shell_unsigned_3 | same as cdsp.mbn | |
| `fastrpc_test -a v68` | PASS | |
