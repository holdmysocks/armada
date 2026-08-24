# TB321FU touchscreen hardware-test image

This branch is a private, disposable lab lane. It is not an Armada-supported
device image, must not be submitted upstream, and must not be used to install
Armada to internal storage. Automatic ABL updates and installer visibility are
disabled deliberately.

The build must use the matching private kernel artifact containing:

- `sm8650-lenovo-tb321fu.dtb`
- `novatek-nt36523n.ko`
- `novatek-nt36523n-report.ko`
- `novatek-nt36523n-firmware.ko`

Pass that kernel carrier by immutable digest with the existing `KERNEL_PKG`
build argument. The default production kernel is expected to fail this branch's
build assertions if it lacks the TB321FU artifact.

The owner may place the private touchscreen firmware at this exact ignored path
before building:

`system_files/usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/novatek_ts_csot_fw.bin`

Do not add or commit that blob. If it is absent, the image still builds but the
three touchscreen modules are explicitly omitted from the initramfs. If it is
present, the build requires all three modules and verifies the firmware,
modules, and blacklist are in the generated initramfs.

The driver is blacklisted from modalias-based automatic loading. After boot,
inspect the DT, regulators, GPIO ownership, and recovery path first. Only then
load it explicitly with `sudo modprobe novatek-nt36523n`.
