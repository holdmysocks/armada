#!/bin/bash
set -euxo pipefail

# Runs after 40-vendor-system-files: the initramfs bundles the armada splash,
# which is not yet installed when the kernel step runs.
KVER="$(ls /usr/lib/modules)"
IMG="/usr/lib/modules/${KVER}/initramfs.img"
HWTEST_MARKER=/usr/lib/armada/tb321fu-hwtest
TOUCH_FIRMWARE=/usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/novatek_ts_csot_fw.bin
GPU_FIRMWARE=/usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn
TOUCH_BLACKLIST=/usr/lib/modprobe.d/90-tb321fu-nt36523n-hwtest.conf
TOUCH_MODULES="novatek-nt36523n novatek-nt36523n-report novatek-nt36523n-firmware"
TB321FU_DTB="/usr/lib/modules/${KVER}/dtb/qcom/sm8650-lenovo-tb321fu.dtb"
NO_ABL_DROPIN=/usr/lib/systemd/system/armada-bootimg-sync.service.d/90-tb321fu-hwtest-no-abl.conf

# Fail closed if this branch is accidentally assembled with a normal Armada
# kernel or without its immutable lab policy files.
test -s "${HWTEST_MARKER}"
test -s "${TB321FU_DTB}"
test -s "${TOUCH_BLACKLIST}"
grep -qx 'sm8650-lenovo-tb321fu' /usr/lib/armada/supported-dtbs
grep -qx 'auto_update_enabled=0' /etc/armada/abl.conf
test -f /usr/lib/armada/abl/TB321FU-HWTEST-NO-ABL
! find /usr/lib/armada/abl -maxdepth 1 -type f -name 'abl_signed-*.elf' -print -quit | grep -q .
grep -qx 'blacklist novatek-nt36523n' "${TOUCH_BLACKLIST}"
test -s "${NO_ABL_DROPIN}"
[[ "$(systemctl is-enabled armada-installer-visibility.service 2>/dev/null || true)" == masked ]]
[[ "$(grep -c '^ExecStop=$' "${NO_ABL_DROPIN}")" == 1 ]]
grep -qx 'ExecStop=/usr/libexec/armada/armada-bootimg-update' "${NO_ABL_DROPIN}"
! grep -q '^ExecStop=.*armada-abl-finalize' "${NO_ABL_DROPIN}"

dracut_args=(
    --force
    --no-hostonly
    --reproducible
    --kver "${KVER}"
    --add ostree
    --add armada-splash
    --add armada-ostree-fallback
)
touch_hwtest_ready=0
touch_firmware_present=0
gpu_firmware_present=0
[[ -e "${TOUCH_FIRMWARE}" || -L "${TOUCH_FIRMWARE}" ]] && touch_firmware_present=1
[[ -e "${GPU_FIRMWARE}" || -L "${GPU_FIRMWARE}" ]] && gpu_firmware_present=1
[[ "${touch_firmware_present}" == "${gpu_firmware_present}" ]] || {
    echo "ERROR: private TB321FU GPU and touchscreen firmware must be supplied together" >&2
    exit 1
}
if [[ "${touch_firmware_present}" == 1 ]]; then
    [[ -f "${TOUCH_FIRMWARE}" && ! -L "${TOUCH_FIRMWARE}" && -s "${TOUCH_FIRMWARE}" ]] || {
        echo "ERROR: private NT36523N firmware must be a nonempty regular file: ${TOUCH_FIRMWARE}" >&2
        exit 1
    }
    [[ -f "${GPU_FIRMWARE}" && ! -L "${GPU_FIRMWARE}" && -s "${GPU_FIRMWARE}" ]] || {
        echo "ERROR: private TB321FU GPU zap must accompany touchscreen firmware: ${GPU_FIRMWARE}" >&2
        exit 1
    }
    for module in ${TOUCH_MODULES}; do
        module_path=$(modinfo -k "${KVER}" -n "${module}") || {
            echo "ERROR: private firmware is present but ${module} is absent from kernel ${KVER}" >&2
            exit 1
        }
        [[ -s "${module_path}" ]] || {
            echo "ERROR: ${module} resolved to missing or empty ${module_path}" >&2
            exit 1
        }
    done
    dracut_args+=(
        --add-drivers "${TOUCH_MODULES}"
        --install "${TOUCH_FIRMWARE} ${GPU_FIRMWARE} ${TOUCH_BLACKLIST}"
    )
    touch_hwtest_ready=1
else
    echo "NOTICE: private NT36523N firmware absent; omitting touchscreen modules from initramfs"
    dracut_args+=(--omit-drivers "${TOUCH_MODULES}")
fi

# fedora-bootc ships /root -> var/roothome, absent in the build container;
# dracut-install aborts resolving /root without the target.
mkdir -p /var/roothome

dracut "${dracut_args[@]}" "${IMG}" "${KVER}"

# dracut drops modules silently: fail the build rather than ship without.
# Exact match: a substring test lets armada-splash-launcher pass for the binary.
contents="$(lsinitrd "${IMG}")"
for required in \
    usr/lib/systemd/system/armada-splash-initrd.service \
    usr/lib/systemd/system/dracut-pre-mount.service.d/armada-splash.conf \
    usr/libexec/armada/armada-splash \
    usr/libexec/armada/armada-splash-launcher \
    usr/libexec/armada/device-env \
    usr/share/armada/splash/splash.asp \
    usr/libexec/armada/armada-ostree-fallback \
    usr/lib/systemd/system/ostree-prepare-root.service.d/armada-fallback.conf \
    usr/lib/ostree/ostree-prepare-root; do
    if ! awk -v p="${required}" '$NF == p { found=1 } END { exit !found }' <<<"${contents}"; then
        echo "ERROR: ${required} missing from initramfs"
        dracut --list-modules --kver "${KVER}" | grep -i armada || true
        exit 1
    fi
done

initrd_has() {
    local pattern=$1
    awk -v pattern="${pattern}" '$NF ~ pattern { found=1 } END { exit !found }' <<<"${contents}"
}

if [[ "${touch_hwtest_ready}" == 1 ]]; then
    for module in ${TOUCH_MODULES}; do
        pattern="usr/lib/modules/.*/kernel/drivers/input/touchscreen/${module}[.]ko([.].*)?$"
        initrd_has "${pattern}" || {
            echo "ERROR: ${module} missing from hardware-test initramfs" >&2
            exit 1
        }
    done
    initrd_has 'usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/novatek_ts_csot_fw[.]bin$' || {
        echo "ERROR: private NT36523N firmware missing from hardware-test initramfs" >&2
        exit 1
    }
    initrd_has 'usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap[.]mbn$' || {
        echo "ERROR: private TB321FU GPU zap missing from hardware-test initramfs" >&2
        exit 1
    }
    initrd_has 'usr/lib/modprobe[.]d/90-tb321fu-nt36523n-hwtest[.]conf$' || {
        echo "ERROR: NT36523N module blacklist missing from hardware-test initramfs" >&2
        exit 1
    }
else
    if initrd_has 'usr/lib/modules/.*/kernel/drivers/input/touchscreen/novatek-nt36523n(-report|-firmware)?[.]ko([.].*)?$'; then
        echo "ERROR: NT36523N module entered initramfs without its private firmware" >&2
        exit 1
    fi
fi

echo "initramfs generated for ${KVER} with armada-splash"
