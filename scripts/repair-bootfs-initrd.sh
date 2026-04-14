#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ROOTFS="$ROOT_DIR/rootfs"
TARGET_BOOTFS="$ROOT_DIR/bootfs"
PACK_DIR="$ROOT_DIR/pack_dir"

KERNEL_VERSION=""
BOOTFS_SIZE="256M"
BOOTFS_UUID=""
MOUNTED_POINTS=()

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'
COLOR_MAGENTA=$'\033[1;35m'

usage() {
    cat <<'EOF'
Usage: sudo scripts/repair-bootfs-initrd.sh [--kernel-version 6.6.63] [--help]

Repair a staged Bianbu build tree after a missing-initrd boot failure by:

1. Restoring the staged /boot tree from bootfs/
2. Entering the staged rootfs with chroot
3. Generating initrd.img-* for the installed kernel
4. Verifying that esos.elf was injected into the initrd
5. Rebuilding bootfs/ and bootfs.ext4 while preserving the existing bootfs UUID
6. Updating pack_dir/bootfs.ext4 so it can be reflashed with:
   sudo bash scripts/eaie_flash.sh --bootfs-only

Options:
  --kernel-version <ver>  Override the detected kernel version.
  --help                  Show this help text.
EOF
}

log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_ok() {
    printf '%s[ OK ]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

log_step() {
    printf '%s[STEP]%s %s\n' "$COLOR_MAGENTA" "$COLOR_RESET" "$*"
}

log_error() {
    printf '%s[ERR ]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

run_as_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

cleanup_mounts() {
    local target
    for target in "${MOUNTED_POINTS[@]}"; do
        run_as_root umount "$target" >/dev/null 2>&1 || true
    done
}

trap cleanup_mounts EXIT

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel-version)
                [[ $# -ge 2 ]] || die "--kernel-version requires a value"
                KERNEL_VERSION="$2"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

require_tools() {
    local missing=()
    local tool
    for tool in rsync blkid mountpoint chroot mke2fs grep sed find; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required host tools: ${missing[*]}"
    fi
}

validate_tree() {
    log_info "Validating the staged build tree"

    [[ -d "$TARGET_ROOTFS" ]] || die "Missing rootfs staging directory: $TARGET_ROOTFS"
    [[ -d "$TARGET_BOOTFS" ]] || die "Missing bootfs staging directory: $TARGET_BOOTFS"
    [[ -d "$PACK_DIR" ]] || die "Missing pack_dir: $PACK_DIR"
    [[ -f "$ROOT_DIR/bootfs.ext4" ]] || die "Missing bootfs.ext4 at the repository root"

    [[ -d "$TARGET_ROOTFS/usr/share/initramfs-tools/hooks" ]] || die "initramfs-tools hooks are missing from the staged rootfs"
    [[ -f "$TARGET_ROOTFS/usr/lib/firmware/esos.elf" || -f "$TARGET_ROOTFS/lib/firmware/esos.elf" ]] || \
        die "esos.elf is missing from the staged rootfs"

    log_ok "The staged rootfs, bootfs, and pack_dir are present"
}

detect_kernel_version() {
    if [[ -n "$KERNEL_VERSION" ]]; then
        log_ok "Using the requested kernel version: $KERNEL_VERSION"
        return
    fi

    KERNEL_VERSION="$(find "$TARGET_BOOTFS" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | head -n 1)"
    [[ -n "$KERNEL_VERSION" ]] || die "Could not detect a kernel version from $TARGET_BOOTFS"

    log_ok "Detected kernel version: $KERNEL_VERSION"
}

discover_bootfs_uuid() {
    BOOTFS_UUID="$(blkid -s UUID -o value "$ROOT_DIR/bootfs.ext4" 2>/dev/null || true)"
    if [[ -z "$BOOTFS_UUID" ]]; then
        BOOTFS_UUID="$(sed -n 's/^UUID=\\([^[:space:]]*\\)[[:space:]]\\+\\/boot[[:space:]].*/\\1/p' "$TARGET_ROOTFS/etc/fstab" | head -n 1)"
    fi
    [[ -n "$BOOTFS_UUID" ]] || die "Could not determine the existing bootfs UUID"

    log_ok "bootfs UUID to preserve: $BOOTFS_UUID"
}

restore_boot_tree() {
    log_info "Restoring the staged /boot tree from bootfs/"
    run_as_root mkdir -p "$TARGET_ROOTFS/boot"
    run_as_root rsync -a --delete "$TARGET_BOOTFS/" "$TARGET_ROOTFS/boot/"
    [[ -f "$TARGET_ROOTFS/boot/vmlinuz-$KERNEL_VERSION" ]] || \
        die "The staged /boot tree is missing vmlinuz-$KERNEL_VERSION after restore"
    log_ok "The staged rootfs now has boot files again"
}

mount_chroot_support() {
    log_info "Mounting chroot support filesystems"

    local source target
    for source in /dev /dev/pts /proc /sys; do
        target="$TARGET_ROOTFS$source"
        run_as_root mkdir -p "$target"
        if mountpoint -q "$target"; then
            continue
        fi
        run_as_root mount --bind "$source" "$target"
        MOUNTED_POINTS=("$target" "${MOUNTED_POINTS[@]}")
    done

    log_ok "The staged rootfs is ready for chroot"
}

generate_initrd() {
    log_info "Generating initrd.img-$KERNEL_VERSION inside the staged rootfs"

    run_as_root chroot "$TARGET_ROOTFS" /bin/bash -lc "update-initramfs -c -k '$KERNEL_VERSION'"

    [[ -f "$TARGET_ROOTFS/boot/initrd.img-$KERNEL_VERSION" ]] || \
        die "initrd generation failed; /boot/initrd.img-$KERNEL_VERSION was not created"

    run_as_root chroot "$TARGET_ROOTFS" /bin/bash -lc \
        "lsinitramfs '/boot/initrd.img-$KERNEL_VERSION' | grep -qx 'usr/lib/firmware/esos.elf'"

    log_ok "initrd.img-$KERNEL_VERSION was generated and contains esos.elf"
}

rebuild_bootfs() {
    log_info "Rebuilding bootfs/ and bootfs.ext4"

    run_as_root rsync -a --delete "$TARGET_ROOTFS/boot/" "$TARGET_BOOTFS/"
    [[ -f "$TARGET_BOOTFS/initrd.img-$KERNEL_VERSION" ]] || \
        die "The rebuilt bootfs tree is missing initrd.img-$KERNEL_VERSION"

    run_as_root rm -f "$ROOT_DIR/bootfs.ext4" "$PACK_DIR/bootfs.ext4"
    run_as_root mke2fs -d "$TARGET_BOOTFS" -L bootfs -t ext4 -U "$BOOTFS_UUID" \
        "$ROOT_DIR/bootfs.ext4" "$BOOTFS_SIZE"
    run_as_root cp "$ROOT_DIR/bootfs.ext4" "$PACK_DIR/bootfs.ext4"

    log_ok "bootfs.ext4 was rebuilt and copied into pack_dir/"
}

main() {
    parse_args "$@"
    require_tools
    validate_tree
    detect_kernel_version
    discover_bootfs_uuid
    restore_boot_tree
    mount_chroot_support
    generate_initrd
    rebuild_bootfs

    log_ok "bootfs repair completed"
    printf '\n'
    printf '%s%s%s\n' "$COLOR_MAGENTA" "Next step:" "$COLOR_RESET"
    printf '  sudo bash scripts/eaie_flash.sh --bootfs-only\n'
}

main "$@"
