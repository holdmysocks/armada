#!/usr/bin/env bash

# The test overrides commands consumed indirectly by the sourced library.
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STORAGE_LIB="$ROOT/system_files/usr/lib/armada/storage-lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$STORAGE_LIB"

# Root/internal comparison remains correct for btrfs subvolume sources.
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/internal-link
    findmnt() { printf '/dev/sda3[/root]\n'; }
    readlink() {
        [[ "${*: -1}" == /dev/internal-link ]] && printf '/dev/sda\n' || printf '%s\n' "${*: -1}"
    }
    lsblk() { printf 'sda\n'; }
    armada_running_from_internal
) || fail "internal root was not recognized"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/internal-link
    findmnt() { printf '/dev/mmcblk0p3[/root]\n'; }
    readlink() {
        [[ "${*: -1}" == /dev/internal-link ]] && printf '/dev/sda\n' || printf '%s\n' "${*: -1}"
    }
    lsblk() { printf 'mmcblk0\n'; }
    armada_running_from_internal
) || fail "external root was mistaken for internal"
! (
    source "$STORAGE_LIB"
    armada_internal_device() { return 1; }
    armada_running_from_internal
) || fail "missing internal device was accepted"

# Native SD remains supported by both the compatibility and generic helpers.
sd="$WORK/sd"
sd_mount="$sd/media/My Card"
mkdir -p "$sd/block/mmcblk0/device" "$sd/block/mmcblk0p1" "$sd_mount"
printf 'SD\n' > "$sd/block/mmcblk0/device/type"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$sd/block"
    ARMADA_MEDIA_ROOT="$sd/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    runuser() { return 0; }
    findmnt() {
        local node=
        while (($#)); do
            if [[ "$1" == -S ]]; then node="$2"; shift 2; else shift; fi
        done
        case "$node" in
            /dev/mmcblk0p1) printf '{"filesystems":[{"target":"%s","options":"rw,nosuid"}]}\n' "$sd_mount" ;;
            *) printf '{"filesystems":[]}\n' ;;
        esac
    }
    [[ "$(armada_mounted_sd)" == "$sd_mount" ]]
    [[ "$(armada_mounted_external)" == "$sd_mount" ]]
) || fail "SD mount discovery regressed"

# Multiple partitions mounted from one SD card remain ambiguous.
sd_many="$WORK/sd-many"
sd_many_a="$sd_many/media/One"
sd_many_b="$sd_many/media/Two"
mkdir -p "$sd_many/block/mmcblk0/device" "$sd_many/block/mmcblk0p1" \
    "$sd_many/block/mmcblk0p2" "$sd_many_a" "$sd_many_b"
printf 'SD\n' > "$sd_many/block/mmcblk0/device/type"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$sd_many/block"
    ARMADA_MEDIA_ROOT="$sd_many/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    runuser() { return 0; }
    findmnt() {
        local node=
        while (($#)); do
            if [[ "$1" == -S ]]; then node="$2"; shift 2; else shift; fi
        done
        case "$node" in
            /dev/mmcblk0p1) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$sd_many_a" ;;
            /dev/mmcblk0p2) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$sd_many_b" ;;
            *) printf '{"filesystems":[]}\n' ;;
        esac
    }
    armada_mounted_sd
) || fail "ambiguous SD mounts were accepted"

# eMMC is not removable SD media.
emmc="$WORK/emmc"
mkdir -p "$emmc/block/mmcblk0/device" "$emmc/media"
printf 'MMC\n' > "$emmc/block/mmcblk0/device/type"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$emmc/block"
    ARMADA_MEDIA_ROOT="$emmc/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    armada_mounted_external
) || fail "eMMC was accepted as external media"

# USB-SCSI media is allowed by transport, not the unreliable removable bit.
usb="$WORK/usb"
usb_mount="$usb/media/Recovery SSD"
mkdir -p "$usb/block/sdb" "$usb/block/sdb1" "$usb_mount"
printf '0\n' > "$usb/block/sdb/removable"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$usb/block"
    ARMADA_MEDIA_ROOT="$usb/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { [[ "${*: -1}" == /dev/sdb ]] && printf 'usb\n'; }
    runuser() { return 0; }
    findmnt() {
        local node=
        while (($#)); do
            if [[ "$1" == -S ]]; then node="$2"; shift 2; else shift; fi
        done
        case "$node" in
            /dev/sdb1) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$usb_mount" ;;
            *) printf '{"filesystems":[]}\n' ;;
        esac
    }
    [[ "$(armada_mounted_external)" == "$usb_mount" ]]
    ! armada_mounted_sd
) || fail "USB-SCSI discovery or SD compatibility behavior is wrong"

# USB NVMe enclosures use p-suffixed partition names.
nvme="$WORK/nvme"
nvme_mount="$nvme/media/NVMe Games"
mkdir -p "$nvme/block/nvme0n1" "$nvme/block/nvme0n1p1" "$nvme_mount"
printf '0\n' > "$nvme/block/nvme0n1/removable"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$nvme/block"
    ARMADA_MEDIA_ROOT="$nvme/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { [[ "${*: -1}" == /dev/nvme0n1 ]] && printf 'usb\n'; }
    runuser() { return 0; }
    findmnt() {
        local node=
        while (($#)); do
            if [[ "$1" == -S ]]; then node="$2"; shift 2; else shift; fi
        done
        case "$node" in
            /dev/nvme0n1p1) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$nvme_mount" ;;
            *) printf '{"filesystems":[]}\n' ;;
        esac
    }
    [[ "$(armada_mounted_external)" == "$nvme_mount" ]]
) || fail "USB NVMe mount was not discovered"

# A UFS LUN is excluded even if its mocked transport metadata says USB.
internal="$WORK/internal"
internal_mount="$internal/media/Internal"
mkdir -p "$internal/block/sda" "$internal/block/sda1" "$internal_mount"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$internal/block"
    ARMADA_MEDIA_ROOT="$internal/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'usb\n'; }
    runuser() { return 0; }
    findmnt() { printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$internal_mount"; }
    armada_mounted_external
) || fail "internal UFS was exposed as external media"

# Non-USB SCSI/NVMe media is outside the allowlist.
fixed="$WORK/fixed"
mkdir -p "$fixed/block/sdb" "$fixed/block/sdb1" "$fixed/media/Fixed"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$fixed/block"
    ARMADA_MEDIA_ROOT="$fixed/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'sata\n'; }
    runuser() { return 0; }
    findmnt() { printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$fixed/media/Fixed"; }
    armada_mounted_external
) || fail "non-USB disk was accepted"

# Multiple usable external mounts are ambiguous and must fail closed.
many="$WORK/many"
many_a="$many/media/One"
many_b="$many/media/Two"
mkdir -p "$many/block/sdb" "$many/block/sdb1" "$many/block/sdc" "$many/block/sdc1" "$many_a" "$many_b"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$many/block"
    ARMADA_MEDIA_ROOT="$many/media"
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'usb\n'; }
    runuser() { return 0; }
    findmnt() {
        local node=
        while (($#)); do
            if [[ "$1" == -S ]]; then node="$2"; shift 2; else shift; fi
        done
        case "$node" in
            /dev/sdb1) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$many_a" ;;
            /dev/sdc1) printf '{"filesystems":[{"target":"%s","options":"rw"}]}\n' "$many_b" ;;
            *) printf '{"filesystems":[]}\n' ;;
        esac
    }
    armada_mounted_external
) || fail "ambiguous external mounts were accepted"

# Read-only, inaccessible, and out-of-root mounts all fail closed.
for rejection in readonly inaccessible outside; do
    reject="$WORK/$rejection"
    reject_media="$reject/media"
    reject_mount="$reject_media/Drive"
    [[ "$rejection" == outside ]] && reject_mount="$reject/outside/Drive"
    mkdir -p "$reject/block/sdb" "$reject/block/sdb1" "$reject_mount" "$reject_media"
    ! (
        source "$STORAGE_LIB"
        ARMADA_INTERNAL_DEVICE=/dev/sda
        ARMADA_BLOCK_CLASS="$reject/block"
        ARMADA_MEDIA_ROOT="$reject_media"
        readlink() { printf '%s\n' "${*: -1}"; }
        lsblk() { [[ "${*: -1}" == /dev/sdb ]] && printf 'usb\n'; }
        runuser() { [[ "$rejection" != inaccessible ]]; }
        findmnt() {
            local options=rw
            [[ "$rejection" == readonly ]] && options=ro
            printf '{"filesystems":[{"target":"%s","options":"%s"}]}\n' "$reject_mount" "$options"
        }
        armada_mounted_external
    ) || fail "$rejection external mount was accepted"
done

# External boot-source probing is read-only and independently testable.
boot_usb="$WORK/boot-usb"
mkdir -p "$boot_usb/block/sdb"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$boot_usb/block"
    armada_root_device() { printf '/dev/sdb\n'; }
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'usb\n'; }
    [[ "$(armada_external_boot_device)" == /dev/sdb ]]
) || fail "USB boot source was not recognized"

boot_nvme="$WORK/boot-nvme"
mkdir -p "$boot_nvme/block/nvme0n1"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$boot_nvme/block"
    armada_root_device() { printf '/dev/nvme0n1\n'; }
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'usb\n'; }
    [[ "$(armada_external_boot_device)" == /dev/nvme0n1 ]]
) || fail "USB NVMe boot source was not recognized"

boot_sd="$WORK/boot-sd"
mkdir -p "$boot_sd/block/mmcblk0/device"
printf 'SD\n' > "$boot_sd/block/mmcblk0/device/type"
(
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$boot_sd/block"
    armada_root_device() { printf '/dev/mmcblk0\n'; }
    readlink() { printf '%s\n' "${*: -1}"; }
    [[ "$(armada_external_boot_device)" == /dev/mmcblk0 ]]
) || fail "SD boot source was not recognized"

boot_internal="$WORK/boot-internal"
mkdir -p "$boot_internal/block/sda"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$boot_internal/block"
    armada_root_device() { printf '/dev/sda\n'; }
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'usb\n'; }
    armada_external_boot_device
) || fail "internal UFS was accepted as an external boot source"

boot_fixed="$WORK/boot-fixed"
mkdir -p "$boot_fixed/block/sdb"
! (
    source "$STORAGE_LIB"
    ARMADA_INTERNAL_DEVICE=/dev/sda
    ARMADA_BLOCK_CLASS="$boot_fixed/block"
    armada_root_device() { printf '/dev/sdb\n'; }
    readlink() { printf '%s\n' "${*: -1}"; }
    lsblk() { printf 'sata\n'; }
    armada_external_boot_device
) || fail "non-USB disk was accepted as an external boot source"

printf 'Storage helper tests passed\n'
