#!/usr/bin/env bash

set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/mnt}"
TARGET_ROOTFS="${TARGET_ROOTFS:-rootfs}"
TARGET_BOOTFS="${TARGET_BOOTFS:-bootfs}"
PACK_DIR="${PACK_DIR:-pack_dir}"
BASE_ROOTFS="${BASE_ROOTFS:-bianbu-base-25.04.2-base-riscv64.tar.gz}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8192M}"
DEFAULT_LOCALE="${DEFAULT_LOCALE:-en_US.UTF-8}"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-America/Sao_Paulo}"
DEFAULT_USER="${DEFAULT_USER:-eaie}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-eaie}"

REPO="archive.spacemit.com/bianbu"
IMAGE_PREFIX="bianbu-custom"

COLOR_RESET=$'\033[0m'
COLOR_CYAN=$'\033[1;36m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[1;31m'

log_info() {
    printf '%s[CONTAINER]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*"
}

log_ok() {
    printf '%s[ OK ]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

die() {
    printf '%s[ERR ]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    exit 1
}

cd "$WORKSPACE"

run_in_chroot() {
    local cmd="$1"
    chroot "$TARGET_ROOTFS" /bin/bash -c "$cmd"
}

enable_rootfs_unit() {
    local unit="$1"
    local unit_path=""
    local base

    for base in \
        "$TARGET_ROOTFS/etc/systemd/system" \
        "$TARGET_ROOTFS/lib/systemd/system" \
        "$TARGET_ROOTFS/usr/lib/systemd/system"; do
        if [[ -f "$base/$unit" ]]; then
            unit_path="$base/$unit"
            break
        fi
    done

    [[ -n "$unit_path" ]] || die "Systemd unit not found in rootfs: $unit"

    mkdir -p "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sf "${unit_path#$TARGET_ROOTFS}" \
        "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants/$unit"
}

mount_rootfs() {
    mkdir -p "$TARGET_ROOTFS/proc" "$TARGET_ROOTFS/sys" "$TARGET_ROOTFS/dev" "$TARGET_ROOTFS/dev/pts"

    mountpoint -q "$TARGET_ROOTFS/proc" || mount -t proc /proc "$TARGET_ROOTFS/proc"
    mountpoint -q "$TARGET_ROOTFS/sys" || mount -t sysfs /sys "$TARGET_ROOTFS/sys"
    mountpoint -q "$TARGET_ROOTFS/dev" || mount -o bind /dev "$TARGET_ROOTFS/dev"
    mountpoint -q "$TARGET_ROOTFS/dev/pts" || mount -o bind /dev/pts "$TARGET_ROOTFS/dev/pts"
}

umount_rootfs() {
    umount -l "$TARGET_ROOTFS/proc" 2>/dev/null || true
    umount -l "$TARGET_ROOTFS/sys" 2>/dev/null || true
    umount -l "$TARGET_ROOTFS/dev/pts" 2>/dev/null || true
    umount -l "$TARGET_ROOTFS/dev" 2>/dev/null || true
}

cleanup() {
    umount_rootfs
}

trap cleanup EXIT

install_container_tools() {
    log_info "Installing container-side build tools"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        genimage \
        python3 \
        rsync \
        uuid-runtime \
        wget \
        zip
    log_ok "Container tools are ready"
}

prepare_rootfs_tree() {
    log_info "Preparing rootfs staging directory"

    if [[ ! -f "$BASE_ROOTFS" ]]; then
        die "Pinned base rootfs tarball not found: $BASE_ROOTFS"
    fi

    mkdir -p "$TARGET_ROOTFS" "$TARGET_BOOTFS" "$PACK_DIR"

    if [[ ! -f "$TARGET_ROOTFS/etc/os-release" ]]; then
        log_info "Extracting base rootfs from $BASE_ROOTFS"
        tar -zxpf "$BASE_ROOTFS" -C "$TARGET_ROOTFS"
    else
        log_ok "Reusing existing rootfs tree"
    fi
}

write_bianbu_sources() {
    log_info "Configuring the pinned Bianbu apt sources"

    cat >"$TARGET_ROOTFS/etc/apt/sources.list.d/bianbu.sources" <<EOF
Types: deb
URIs: https://$REPO/
Suites: plucky/snapshots/v3.0 plucky-security/snapshots/v3.0 plucky-updates/snapshots/v3.0 plucky-porting/snapshots/v3.0 plucky-customization/snapshots/v3.0 bianbu-v3.0-updates
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/bianbu-archive-keyring.gpg
EOF

    printf 'nameserver 8.8.8.8\n' >"$TARGET_ROOTFS/etc/resolv.conf"
}

install_rootfs_packages() {
    log_info "Installing hardware support, desktop packages, and required extras"

    run_in_chroot "apt-get update"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades upgrade"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install initramfs-tools"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install bianbu-esos img-gpu-powervr k1x-vpu-firmware k1x-cam spacemit-uart-bt spacemit-modules-usrload opensbi-spacemit u-boot-spacemit linux-generic"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install bianbu-minimal"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install bianbu-desktop-lite"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install locales language-pack-en qt6-wayland xterm net-tools cloud-guest-utils sudo openssh-server"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install --reinstall qt6-wayland"
}

repair_and_validate_packages() {
    log_info "Repairing and validating package state"

    run_in_chroot "dpkg --configure -a"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -f install -y"
    run_in_chroot "dpkg --configure -a"

    local bad_state
    bad_state="$(run_in_chroot "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' | awk '\$1 !~ /^(ii|rc)$/ {print}'" || true)"
    if [[ -n "$bad_state" ]]; then
        printf '%s\n' "$bad_state" >&2
        die "The rootfs still contains incomplete packages. Failing hard as requested."
    fi

    run_in_chroot "ls /usr/lib/riscv64-linux-gnu/qt6/plugins/platforms/libqwayland*.so >/dev/null"
    run_in_chroot "command -v growpart >/dev/null"
    run_in_chroot "command -v sshd >/dev/null"

    log_ok "Package state is clean and required runtime pieces are present"
}

configure_locale_timezone() {
    log_info "Configuring locale and timezone"

    run_in_chroot "printf '%s UTF-8\n' '$DEFAULT_LOCALE' > /etc/locale.gen"
    run_in_chroot "locale-gen '$DEFAULT_LOCALE'"
    run_in_chroot "update-locale LANG='$DEFAULT_LOCALE' LC_ALL='$DEFAULT_LOCALE'"
    run_in_chroot "printf 'LANG=%s\nLC_ALL=%s\n' '$DEFAULT_LOCALE' '$DEFAULT_LOCALE' > /etc/default/locale"
    run_in_chroot "printf 'LANG=%s\nLC_ALL=%s\n' '$DEFAULT_LOCALE' '$DEFAULT_LOCALE' > /etc/locale.conf"

    run_in_chroot "ln -snf '/usr/share/zoneinfo/$DEFAULT_TIMEZONE' /etc/localtime"
    run_in_chroot "printf '%s\n' '$DEFAULT_TIMEZONE' > /etc/timezone"
    run_in_chroot "dpkg-reconfigure --frontend=noninteractive tzdata"

    log_ok "Locale and timezone configured"
}

configure_users() {
    log_info "Configuring development users and passwords"

    run_in_chroot "echo root:$DEFAULT_PASSWORD | chpasswd"

    run_in_chroot "id -u '$DEFAULT_USER' >/dev/null 2>&1 || useradd -m -s /bin/bash '$DEFAULT_USER'"
    run_in_chroot "echo '$DEFAULT_USER:$DEFAULT_PASSWORD' | chpasswd"

    local groups=(adm audio cdrom dialout dip input lpadmin netdev plugdev render sudo users video)
    local group
    for group in "${groups[@]}"; do
        run_in_chroot "getent group '$group' >/dev/null 2>&1 && usermod -aG '$group' '$DEFAULT_USER' || true"
    done

    run_in_chroot "chown -R '$DEFAULT_USER:$DEFAULT_USER' '/home/$DEFAULT_USER'"

    log_ok "Development accounts configured"
}

configure_network() {
    log_info "Configuring NetworkManager netplan for the desktop image"

    cat >"$TARGET_ROOTFS/etc/netplan/01-network-manager-all.yaml" <<'EOF'
# Let NetworkManager manage all devices on this system.
network:
  version: 2
  renderer: NetworkManager
EOF

    chmod 600 "$TARGET_ROOTFS/etc/netplan/01-network-manager-all.yaml"
    log_ok "NetworkManager netplan is configured"
}

configure_ssh() {
    log_info "Enabling SSH for the development image"

    mkdir -p "$TARGET_ROOTFS/etc/ssh/sshd_config.d"
    cat >"$TARGET_ROOTFS/etc/ssh/sshd_config.d/90-eaie-development.conf" <<'EOF'
# Development-only SSH defaults. Tighten this before any production use.
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF

    install -Dm0644 "$WORKSPACE/scripts/assets/ssh-hostkeys.service" \
        "$TARGET_ROOTFS/etc/systemd/system/ssh-hostkeys.service"

    rm -f "$TARGET_ROOTFS"/etc/ssh/ssh_host_*

    enable_rootfs_unit ssh-hostkeys.service
    enable_rootfs_unit ssh.service

    log_ok "SSH is enabled and host keys will be generated uniquely on first boot"
}

configure_sddm_autologin() {
    log_info "Replacing the OEM Calamares autologin flow with a normal LXQt Wayland autologin"

    # Development-only convenience. This is intentionally insecure and must be
    # revisited before any production or externally exposed deployment.
    cat >"$TARGET_ROOTFS/etc/sddm.conf" <<EOF
[Theme]
Current=astronaut

[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=xdg-shell

[Wayland]
CompositorCommand=labwc
SessionDir=/usr/share/wayland-sessions/

[Autologin]
# Development-only convenience. Replace or remove this before shipping.
Session=lxqt-wayland
User=$DEFAULT_USER

[Users]
HideUsers=initer
EOF

    log_ok "SDDM is configured for LXQt Wayland autologin"
}

install_rootfs_expand_service() {
    log_info "Installing the first-boot rootfs auto-expand service"

    install -Dm0755 "$WORKSPACE/scripts/assets/expand-rootfs.sh" \
        "$TARGET_ROOTFS/usr/local/sbin/expand-rootfs.sh"
    install -Dm0644 "$WORKSPACE/scripts/assets/expand-rootfs.service" \
        "$TARGET_ROOTFS/etc/systemd/system/expand-rootfs.service"

    mkdir -p "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sf ../expand-rootfs.service \
        "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants/expand-rootfs.service"

    log_ok "First-boot rootfs expansion is enabled"
}

prepare_fstab_and_partition_images() {
    log_info "Preparing bootfs/rootfs partition images"

    local uuid_bootfs uuid_rootfs
    uuid_bootfs="$(uuidgen)"
    uuid_rootfs="$(uuidgen)"

    cat >"$TARGET_ROOTFS/etc/fstab" <<EOF
# <file system>     <dir>    <type>  <options>                          <dump> <pass>
UUID=$uuid_rootfs   /        ext4    defaults,noatime,errors=remount-ro 0      1
UUID=$uuid_bootfs   /boot    ext4    defaults                           0      2
EOF

    mkdir -p "$TARGET_BOOTFS"

    if find "$TARGET_ROOTFS/boot" -mindepth 1 -maxdepth 1 | read -r _; then
        rm -rf "$TARGET_BOOTFS"/*
        rsync -a "$TARGET_ROOTFS/boot/" "$TARGET_BOOTFS/"
        rm -rf "$TARGET_ROOTFS/boot/"*
    elif ! find "$TARGET_BOOTFS" -mindepth 1 -maxdepth 1 | read -r _; then
        die "Neither $TARGET_ROOTFS/boot nor $TARGET_BOOTFS contain boot files."
    else
        log_warn "Reusing existing $TARGET_BOOTFS contents because $TARGET_ROOTFS/boot is already empty"
    fi

    rm -f bootfs.ext4 rootfs.ext4
    mke2fs -d "$TARGET_BOOTFS" -L bootfs -t ext4 -U "$uuid_bootfs" bootfs.ext4 "256M"
    mke2fs -d "$TARGET_ROOTFS" -L rootfs -t ext4 -N 524288 -U "$uuid_rootfs" rootfs.ext4 "$ROOTFS_SIZE"

    log_ok "bootfs.ext4 and rootfs.ext4 were generated"
}

prepare_pack_dir() {
    log_info "Preparing image packaging inputs"

    mkdir -p "$PACK_DIR/factory"

    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_emmc.bin" "$PACK_DIR/factory/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_sd.bin" "$PACK_DIR/factory/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_spinand.bin" "$PACK_DIR/factory/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_spinor.bin" "$PACK_DIR/factory/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/FSBL.bin" "$PACK_DIR/factory/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/u-boot.itb" "$PACK_DIR/"
    cp "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/env.bin" "$PACK_DIR/"
    cp "$TARGET_ROOTFS/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.itb" "$PACK_DIR/"
    cp bootfs.ext4 "$PACK_DIR/"
    cp rootfs.ext4 "$PACK_DIR/"

    for required in \
        "$PACK_DIR/fastboot.yaml" \
        "$PACK_DIR/partition_2M.json" \
        "$PACK_DIR/partition_flash.json" \
        "$PACK_DIR/partition_universal.json" \
        "$PACK_DIR/gen_imgcfg.py"; do
        [[ -f "$required" ]] || die "Missing pinned packaging helper: $required"
    done

    log_ok "Packaging inputs are ready"
}

package_titan_zip() {
    log_info "Packaging Titan flash zip"
    rm -f "${IMAGE_PREFIX}.zip"
    (
        cd "$PACK_DIR"
        zip -rq "../${IMAGE_PREFIX}.zip" .
    )
    log_ok "${IMAGE_PREFIX}.zip created"
}

package_sdcard_image() {
    log_info "Packaging SD card image"
    python3 "$PACK_DIR/gen_imgcfg.py" \
        -i "$PACK_DIR/partition_universal.json" \
        -n "${IMAGE_PREFIX}.sdcard" \
        -o "$PACK_DIR/genimage.cfg"

    local rootpath_tmp genimage_tmp
    rootpath_tmp="$(mktemp -d)"
    genimage_tmp="$(mktemp -d)"

    rm -f "${IMAGE_PREFIX}.sdcard"
    genimage \
        --config "$PACK_DIR/genimage.cfg" \
        --rootpath "$rootpath_tmp" \
        --tmppath "$genimage_tmp" \
        --inputpath "$PACK_DIR" \
        --outputpath "."

    rm -rf "$rootpath_tmp" "$genimage_tmp"
    log_ok "${IMAGE_PREFIX}.sdcard created"
}

cleanup_rootfs_caches() {
    log_info "Cleaning apt cache inside the rootfs"
    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get clean"
}

main() {
    install_container_tools
    prepare_rootfs_tree
    mount_rootfs
    write_bianbu_sources
    install_rootfs_packages
    repair_and_validate_packages
    configure_locale_timezone
    configure_users
    configure_network
    configure_ssh
    configure_sddm_autologin
    install_rootfs_expand_service
    cleanup_rootfs_caches
    umount_rootfs
    prepare_fstab_and_partition_images
    prepare_pack_dir
    package_titan_zip
    package_sdcard_image
}

main "$@"
