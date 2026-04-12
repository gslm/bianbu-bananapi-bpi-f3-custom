#!/usr/bin/env bash

set -Eeuo pipefail

STAMP_DIR="/var/lib/bianbu-build"
STAMP_FILE="${STAMP_DIR}/rootfs-expanded"

mkdir -p "$STAMP_DIR"

if [[ -f "$STAMP_FILE" ]]; then
    exit 0
fi

ROOT_DEV="$(findmnt -n -o SOURCE / || true)"
if [[ -z "$ROOT_DEV" ]]; then
    echo "expand-rootfs: unable to detect the mounted root device" >&2
    exit 1
fi

if [[ -e "$ROOT_DEV" ]]; then
    ROOT_DEV="$(readlink -f "$ROOT_DEV")"
fi

if [[ "$ROOT_DEV" == "/dev/root" && -e /dev/root ]]; then
    ROOT_DEV="$(readlink -f /dev/root)"
fi

if [[ "$ROOT_DEV" != /dev/* ]]; then
    echo "expand-rootfs: unsupported root device path: $ROOT_DEV" >&2
    exit 1
fi

ROOT_DISK_NAME="$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)"
ROOT_PART_NUMBER="$(lsblk -no PARTN "$ROOT_DEV" | head -n1)"

if [[ -z "$ROOT_DISK_NAME" || -z "$ROOT_PART_NUMBER" ]]; then
    echo "expand-rootfs: unable to resolve disk and partition for $ROOT_DEV" >&2
    exit 1
fi

ROOT_DISK="/dev/${ROOT_DISK_NAME}"

growpart "$ROOT_DISK" "$ROOT_PART_NUMBER" || {
    echo "expand-rootfs: growpart failed for $ROOT_DISK partition $ROOT_PART_NUMBER" >&2
    exit 1
}

partprobe "$ROOT_DISK" || true
udevadm settle || true
resize2fs "$ROOT_DEV"

touch "$STAMP_FILE"
systemctl disable expand-rootfs.service >/dev/null 2>&1 || true

