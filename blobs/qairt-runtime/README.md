# qairt-runtime blobs (Qualcomm QAIRT/QNN SDK)

Off by default. To enable QNN/HTP inference later, download the QAIRT SDK
(Qualcomm AI Engine Direct, `aarch64-ubuntu-gcc` variant) and drop:

```
blobs/qairt-runtime/usr/lib/libQnnHtp.so
blobs/qairt-runtime/usr/lib/libQnnHtpV68Stub.so
blobs/qairt-runtime/usr/lib/libQnnSystem.so
blobs/qairt-runtime/usr/lib/libQnnHtpPrepare.so
blobs/qairt-runtime/usr/bin/qnn-platform-validator          (optional)
blobs/qairt-runtime/usr/lib/dsp/libQnnHtpV68Skel.so         (DSP-side skel)
```

Then set `BR2_PACKAGE_QAIRT_RUNTIME=y` in `nerves_defconfig`. Not needed for
the `fastrpc_test -a v68` acceptance test.
