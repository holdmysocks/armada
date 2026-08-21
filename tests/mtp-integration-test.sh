#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GADGET="$ROOT/system_files/usr/libexec/armada/mtp-gadget"
UNIT="$ROOT/system_files/usr/lib/systemd/system/armada-mtp.service"
CONTROL="$ROOT/system_files/usr/libexec/armada/armada-control"
STORAGE_LIB="$ROOT/system_files/usr/lib/armada/storage-lib"
INSTALLER_VISIBILITY="$ROOT/system_files/usr/libexec/armada/installer-visibility"

bash -n "$GADGET"
bash -n "$STORAGE_LIB"
bash -n "$INSTALLER_VISIBILITY"
grep -Fq 'storage "/var/home/armada" "Home" "rw"' "$GADGET"
grep -Fq 'source /usr/lib/armada/storage-lib' "$GADGET"
grep -Fq 'armada_running_from_internal && external_source=$(armada_mounted_external)' "$GADGET"
grep -Fq 'ln -sfn -- "$external_source" "$external_link"' "$GADGET"
grep -Fq 'storage "/run/armada-mtp/external" "External Storage" "rw,removable"' "$GADGET"
# A bind mount pins the card and defeats safe ejection.
! grep -Fq 'mount --bind' "$GADGET"
grep -Fq 'show_hidden_files 0' "$GADGET"
grep -Fq 'armada_running_from_internal && exit 0' "$INSTALLER_VISIBILITY"
grep -Fq 'systemd-id128 machine-id -a' "$GADGET"
! grep -Fq 'serial=armada' "$GADGET"
grep -Fq 'armada_uid="$(id -u armada)"' "$GADGET"
grep -Fq 'stale USB gadget exists' "$GADGET"
grep -Fq 'no USB device controller found' "$GADGET"
grep -Fq 'ExecStartPost=+/usr/libexec/armada/mtp-gadget bind' "$UNIT"
grep -Fq 'ExecStart=/usr/bin/umtprd -conf /run/armada-mtp/umtprd.conf' "$UNIT"
grep -Fq 'ExecStopPost=+/usr/libexec/armada/mtp-gadget teardown' "$UNIT"
! grep -Fq 'PrivateTmp=' "$UNIT"
! grep -Fq '[Install]' "$UNIT"
grep -Fq '"set_mtp_enabled": action_set_mtp_enabled' "$CONTROL"
grep -Fq 'action = "start" if enabled else "stop"' "$CONTROL"
! grep -Fq 'action, "--now", "armada-mtp.service"' "$CONTROL"
# Defense in depth if the unit becomes enableable again.
grep -Fq 'systemctl disable armada-mtp.service' "$ROOT/build_files/40-vendor-system-files.sh"
grep -Fq 'umtp-responder@sha256:' "$ROOT/Containerfile"

printf 'MTP integration test passed\n'
