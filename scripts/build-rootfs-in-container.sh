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
ALLOW_PARTIAL_ROOTFS="${ALLOW_PARTIAL_ROOTFS:-1}"
BOARD_PROFILE="${BOARD_PROFILE:-bpi-f3}"
BOARD_SOURCE_DTB_NAME="${BOARD_SOURCE_DTB_NAME:-k1-x_deb1}"
BOARD_RUNTIME_DTB_NAME="${BOARD_RUNTIME_DTB_NAME:-k1-x_deb1}"
BOARD_BOOT_ENV_NAME="${BOARD_BOOT_ENV_NAME:-env_k1-x.txt}"
KERNEL_MODE="${KERNEL_MODE:-source}"
UBOOT_MODE="${UBOOT_MODE:-source}"
KERNEL_SOURCE_DEB="${KERNEL_SOURCE_DEB:-}"
UBOOT_SOURCE_DEB="${UBOOT_SOURCE_DEB:-}"

REPO="archive.spacemit.com/bianbu"
IMAGE_PREFIX="bianbu-custom"
FIRSTBOOT_REPAIR_STATE_DIR="/var/lib/eaie-firstboot-repair"
FIRSTBOOT_REPAIR_MARKER="${FIRSTBOOT_REPAIR_STATE_DIR}/enabled"
PARTIAL_BUILD=0
CORE_BOOT_PACKAGES=""
REPAIR_PACKAGES=""
PRIMARY_KERNEL_VERSION=""

COLOR_RESET=$'\033[0m'
COLOR_CYAN=$'\033[1;36m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[1;31m'
BUILD_START_EPOCH=0
declare -a PHASE_NAMES=()
declare -a PHASE_SECONDS=()

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

format_duration() {
    local total_millis="${1:-0}"
    local total_seconds millis hours minutes seconds

    total_seconds=$((total_millis / 1000))
    millis=$((total_millis % 1000))
    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [[ "$hours" -gt 0 ]]; then
        printf '%dh %02dm %02d.%03ds' "$hours" "$minutes" "$seconds" "$millis"
        return
    fi

    if [[ "$minutes" -gt 0 ]]; then
        printf '%dm %02d.%03ds' "$minutes" "$seconds" "$millis"
        return
    fi

    if [[ "$total_seconds" -gt 0 ]]; then
        printf '%d.%03ds' "$seconds" "$millis"
        return
    fi

    printf '%dms' "$total_millis"
}

now_millis() {
    local now
    now="$(date +%s%3N 2>/dev/null || true)"
    if [[ -z "$now" || "$now" == *N ]]; then
        now="$(( $(date +%s) * 1000 ))"
    fi
    printf '%s\n' "$now"
}

record_phase_duration() {
    PHASE_NAMES+=("$1")
    PHASE_SECONDS+=("$2")
}

run_timed_phase() {
    local label="$1"
    local start_epoch end_epoch elapsed
    shift

    start_epoch="$(now_millis)"
    "$@"
    end_epoch="$(now_millis)"
    elapsed=$((end_epoch - start_epoch))

    record_phase_duration "$label" "$elapsed"
    log_ok "Phase complete: $label ($(format_duration "$elapsed"))"
}

print_timing_summary() {
    local total_seconds="$1"
    local i

    printf '\n'
    printf '%s[SUMMARY]%s Container build timings\n' "$COLOR_CYAN" "$COLOR_RESET"
    for ((i = 0; i < ${#PHASE_NAMES[@]}; i++)); do
        printf '  - %s: %s\n' "${PHASE_NAMES[$i]}" "$(format_duration "${PHASE_SECONDS[$i]}")"
    done
    printf '  - Total container build time: %s\n' "$(format_duration "$total_seconds")"
}

cd "$WORKSPACE"

ensure_riscv_loader_compat() {
    local usr_loader="$TARGET_ROOTFS/usr/lib/ld-linux-riscv64-lp64d.so.1"
    local compat_loader="$TARGET_ROOTFS/lib/ld-linux-riscv64-lp64d.so.1"
    local usr_multiarch_dir="$TARGET_ROOTFS/usr/lib/riscv64-linux-gnu"
    local compat_multiarch_dir="$TARGET_ROOTFS/lib/riscv64-linux-gnu"

    [[ -e "$usr_loader" ]] || die "The staged rootfs is missing the RISC-V dynamic loader: $usr_loader"

    if [[ ! -e "$TARGET_ROOTFS/lib" ]]; then
        mkdir -p "$TARGET_ROOTFS/lib"
    fi

    if [[ ! -L "$TARGET_ROOTFS/lib" ]]; then
        ln -sfn ../usr/lib/ld-linux-riscv64-lp64d.so.1 "$compat_loader"
        if [[ -d "$usr_multiarch_dir" && ! -e "$compat_multiarch_dir" ]]; then
            ln -sfn ../usr/lib/riscv64-linux-gnu "$compat_multiarch_dir"
        fi
    fi
}

run_in_chroot() {
    local cmd="$1"
    ensure_riscv_loader_compat
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

enable_rootfs_unit_if_present() {
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

    if [[ -n "$unit_path" ]]; then
        mkdir -p "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants"
        ln -sf "${unit_path#$TARGET_ROOTFS}" \
            "$TARGET_ROOTFS/etc/systemd/system/multi-user.target.wants/$unit"
        return
    fi

    log_warn "Systemd unit is not present in the current rootfs yet: $unit"
}

set_ini_key() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"

    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
        return
    fi

    if grep -q "^\[${section}\]" "$file"; then
        sed -i "/^\[${section}\]/a ${key}=${value}" "$file"
        return
    fi

    printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >>"$file"
}

validate_build_modes() {
    case "$KERNEL_MODE" in
        source|default) ;;
        *) die "Unsupported kernel mode: $KERNEL_MODE" ;;
    esac

    case "$UBOOT_MODE" in
        source|default) ;;
        *) die "Unsupported U-Boot mode: $UBOOT_MODE" ;;
    esac

    [[ -n "$BOARD_PROFILE" ]] || die "BOARD_PROFILE is not set"
    [[ -n "$BOARD_SOURCE_DTB_NAME" ]] || die "BOARD_SOURCE_DTB_NAME is not set"
    [[ -n "$BOARD_RUNTIME_DTB_NAME" ]] || die "BOARD_RUNTIME_DTB_NAME is not set"
    [[ -n "$BOARD_BOOT_ENV_NAME" ]] || die "BOARD_BOOT_ENV_NAME is not set"
}

compose_package_sets() {
    local packages=(
        initramfs-tools
        bianbu-esos
        img-gpu-powervr
        k1x-vpu-firmware
        k1x-cam
        spacemit-uart-bt
        spacemit-modules-usrload
        opensbi-spacemit
    )

    if [[ "$KERNEL_MODE" == "default" ]]; then
        packages+=(linux-generic)
    else
        [[ -n "$KERNEL_SOURCE_DEB" ]] || die "Kernel source mode requires KERNEL_SOURCE_DEB to be set"
    fi

    if [[ "$UBOOT_MODE" == "default" ]]; then
        packages+=(u-boot-spacemit)
    else
        [[ -n "$UBOOT_SOURCE_DEB" ]] || die "U-Boot source mode requires UBOOT_SOURCE_DEB to be set"
    fi

    CORE_BOOT_PACKAGES="${packages[*]}"
    REPAIR_PACKAGES="${CORE_BOOT_PACKAGES} bianbu-minimal bianbu-desktop-lite locales language-pack-en qt6-wayland xterm net-tools cloud-guest-utils sudo openssh-server ffmpeg tpm2-tools"
}

resolve_workspace_path() {
    local path="$1"

    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
        return
    fi

    printf '%s/%s\n' "$WORKSPACE" "$path"
}

cleanup_staged_kernel_artifacts() {
    rm -rf "$TARGET_ROOTFS/boot/spacemit" \
        "$TARGET_ROOTFS/lib/modules/"* \
        "$TARGET_ROOTFS/usr/lib/linux-image-"*
    rm -f "$TARGET_ROOTFS/boot"/vmlinuz-* \
        "$TARGET_ROOTFS/boot"/initrd.img-* \
        "$TARGET_ROOTFS/boot"/System.map-* \
        "$TARGET_ROOTFS/boot"/config-* \
        "$TARGET_ROOTFS/boot/$BOARD_BOOT_ENV_NAME"
}

cleanup_staged_uboot_artifacts() {
    rm -rf "$TARGET_ROOTFS/usr/lib/u-boot/spacemit"
}

detect_primary_kernel_version() {
    PRIMARY_KERNEL_VERSION="$(find "$TARGET_ROOTFS/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' \
        | sed 's/^vmlinuz-//' \
        | sort -V \
        | tail -n 1)"

    [[ -n "$PRIMARY_KERNEL_VERSION" ]] || die "Could not detect a primary kernel version from $TARGET_ROOTFS/boot"
}

stage_kernel_dtbs_into_boot() {
    local source_dtb_dir
    local boot_dtb_dir

    detect_primary_kernel_version
    source_dtb_dir="$TARGET_ROOTFS/usr/lib/linux-image-$PRIMARY_KERNEL_VERSION/spacemit"
    boot_dtb_dir="$TARGET_ROOTFS/boot/spacemit/$PRIMARY_KERNEL_VERSION"

    [[ -d "$source_dtb_dir" ]] || die "The source-built kernel package does not provide SpacemiT DTBs under $source_dtb_dir"

    mkdir -p "$boot_dtb_dir"
    rsync -a --delete "$source_dtb_dir/" "$boot_dtb_dir/"
}

ensure_runtime_dtb_aliases() {
    local source_dtb_dir
    local boot_dtb_dir
    local source_usr_dtb
    local runtime_usr_dtb
    local source_boot_dtb
    local runtime_boot_dtb

    detect_primary_kernel_version
    source_dtb_dir="$TARGET_ROOTFS/usr/lib/linux-image-$PRIMARY_KERNEL_VERSION/spacemit"
    boot_dtb_dir="$TARGET_ROOTFS/boot/spacemit/$PRIMARY_KERNEL_VERSION"

    source_usr_dtb="$source_dtb_dir/$BOARD_SOURCE_DTB_NAME.dtb"
    source_boot_dtb="$boot_dtb_dir/$BOARD_SOURCE_DTB_NAME.dtb"
    runtime_usr_dtb="$source_dtb_dir/$BOARD_RUNTIME_DTB_NAME.dtb"
    runtime_boot_dtb="$boot_dtb_dir/$BOARD_RUNTIME_DTB_NAME.dtb"

    [[ -f "$source_usr_dtb" ]] || die "The selected board source DTB is missing from the staged kernel package: $source_usr_dtb"
    [[ -f "$source_boot_dtb" ]] || die "The selected board source DTB is missing from the staged /boot tree: $source_boot_dtb"

    if [[ "$BOARD_SOURCE_DTB_NAME" != "$BOARD_RUNTIME_DTB_NAME" ]]; then
        cp -f "$source_usr_dtb" "$runtime_usr_dtb"
        cp -f "$source_boot_dtb" "$runtime_boot_dtb"
        log_ok "Installed board DTB runtime alias $BOARD_RUNTIME_DTB_NAME.dtb from $BOARD_SOURCE_DTB_NAME.dtb"
        return
    fi

    log_ok "Board DTB selection uses $BOARD_RUNTIME_DTB_NAME.dtb directly"
}

apply_kernel_source_deb() {
    local source_deb
    local unpack_dir
    source_deb="$(resolve_workspace_path "$KERNEL_SOURCE_DEB")"

    [[ -f "$source_deb" ]] || die "Kernel source package not found: $source_deb"

    log_info "Overlaying kernel artifacts from source package $(basename "$source_deb")"
    cleanup_staged_kernel_artifacts
    unpack_dir="$(mktemp -d)"
    dpkg-deb -x "$source_deb" "$unpack_dir"

    [[ -d "$unpack_dir/boot" ]] && rsync -a "$unpack_dir/boot/" "$TARGET_ROOTFS/boot/"
    [[ -d "$unpack_dir/etc" ]] && rsync -a "$unpack_dir/etc/" "$TARGET_ROOTFS/etc/"
    [[ -d "$unpack_dir/lib" ]] && rsync -a "$unpack_dir/lib/" "$TARGET_ROOTFS/lib/"
    [[ -d "$unpack_dir/usr" ]] && rsync -a "$unpack_dir/usr/" "$TARGET_ROOTFS/usr/"
    rm -rf "$unpack_dir"

    detect_primary_kernel_version
    stage_kernel_dtbs_into_boot
    ensure_runtime_dtb_aliases
    if ! run_in_chroot "depmod '$PRIMARY_KERNEL_VERSION'"; then
        log_warn "depmod did not complete cleanly for the source-built kernel $PRIMARY_KERNEL_VERSION"
    fi

    log_ok "Source-built kernel artifacts were staged into the rootfs"
}

apply_uboot_source_deb() {
    local source_deb
    source_deb="$(resolve_workspace_path "$UBOOT_SOURCE_DEB")"

    [[ -f "$source_deb" ]] || die "U-Boot source package not found: $source_deb"

    log_info "Overlaying U-Boot artifacts from source package $(basename "$source_deb")"
    cleanup_staged_uboot_artifacts
    dpkg-deb -x "$source_deb" "$TARGET_ROOTFS"

    log_ok "Source-built U-Boot artifacts were staged into the rootfs"
}

apply_source_package_overlays() {
    if [[ "$KERNEL_MODE" == "source" ]]; then
        apply_kernel_source_deb
    fi

    if [[ "$UBOOT_MODE" == "source" ]]; then
        apply_uboot_source_deb
    fi
}

update_boot_env_txt() {
    local dtb_version=""

    detect_primary_kernel_version
    [[ -d "$TARGET_ROOTFS/boot/spacemit" ]] || die "The staged /boot tree does not contain a spacemit DTB directory"

    if [[ -d "$TARGET_ROOTFS/boot/spacemit/$PRIMARY_KERNEL_VERSION" ]]; then
        dtb_version="$PRIMARY_KERNEL_VERSION"
    else
        dtb_version="$(find "$TARGET_ROOTFS/boot/spacemit" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
    fi

    [[ -n "$dtb_version" ]] || die "Could not determine the DTB directory version for $BOARD_BOOT_ENV_NAME"

    cat >"$TARGET_ROOTFS/boot/$BOARD_BOOT_ENV_NAME" <<EOF
knl_name=vmlinuz-$PRIMARY_KERNEL_VERSION
ramdisk_name=initrd.img-$PRIMARY_KERNEL_VERSION
dtb_dir=spacemit/$dtb_version
EOF

    log_ok "Updated $BOARD_BOOT_ENV_NAME for kernel $PRIMARY_KERNEL_VERSION"
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

prepare_chroot_environment() {
    mount_rootfs
    write_bianbu_sources
}

install_rootfs_packages() {
    log_info "Installing hardware support, desktop packages, and required extras"

    run_in_chroot "apt-get update"
    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install ${CORE_BOOT_PACKAGES}"; then
        PARTIAL_BUILD=1
        log_warn "Core package installation failed under qemu. The build will continue in partial-repair mode."
    fi

    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install bianbu-minimal"; then
        PARTIAL_BUILD=1
        log_warn "bianbu-minimal did not install cleanly under qemu. Deferring repair to first boot."
    fi

    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install bianbu-desktop-lite"; then
        PARTIAL_BUILD=1
        log_warn "bianbu-desktop-lite did not install cleanly under qemu. Deferring repair to first boot."
    fi

    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install locales language-pack-en qt6-wayland xterm net-tools cloud-guest-utils sudo openssh-server ffmpeg tpm2-tools"; then
        PARTIAL_BUILD=1
        log_warn "Customization packages did not install cleanly under qemu. Deferring repair to first boot."
    fi

    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades install --reinstall qt6-wayland"; then
        PARTIAL_BUILD=1
        log_warn "qt6-wayland reinstall failed under qemu. Deferring repair to first boot."
    fi
}

repair_and_validate_packages() {
    log_info "Repairing and validating package state"

    local final_bad_state=""

    if ! run_in_chroot "dpkg --configure -a"; then
        PARTIAL_BUILD=1
        log_warn "dpkg --configure -a did not complete cleanly under qemu."
    fi

    if ! run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get -f install -y"; then
        PARTIAL_BUILD=1
        log_warn "apt-get -f install did not complete cleanly under qemu."
    fi

    if ! run_in_chroot "dpkg --configure -a"; then
        PARTIAL_BUILD=1
        log_warn "A second dpkg --configure -a pass still failed under qemu."
    fi

    local bad_state
    bad_state="$(run_in_chroot "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' | awk '\$1 !~ /^(ii|rc)$/ {print}'" || true)"
    if [[ -n "$bad_state" ]]; then
        PARTIAL_BUILD=1
        printf '%s\n' "$bad_state" >&2
        if [[ "$ALLOW_PARTIAL_ROOTFS" -ne 1 ]]; then
            die "The rootfs still contains incomplete packages."
        fi
        log_warn "The rootfs still contains incomplete packages. A native first-boot repair will be scheduled."
    fi

    if ! run_in_chroot "ls /usr/lib/riscv64-linux-gnu/qt6/plugins/platforms/libqwayland*.so >/dev/null"; then
        PARTIAL_BUILD=1
        log_warn "The Qt6 Wayland platform plugin is still missing in the container rootfs."
    fi

    if ! run_in_chroot "command -v growpart >/dev/null"; then
        PARTIAL_BUILD=1
        log_warn "growpart is not present yet in the container rootfs."
    fi

    if ! run_in_chroot "command -v sshd >/dev/null"; then
        PARTIAL_BUILD=1
        log_warn "openssh-server is not present yet in the container rootfs."
    fi

    final_bad_state="$(run_in_chroot "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' | awk '\$1 !~ /^(ii|rc)$/ {print}'" || true)"
    if [[ -z "$final_bad_state" ]] \
        && run_in_chroot "ls /usr/lib/riscv64-linux-gnu/qt6/plugins/platforms/libqwayland*.so >/dev/null" \
        && run_in_chroot "command -v growpart >/dev/null" \
        && run_in_chroot "command -v sshd >/dev/null"; then
        PARTIAL_BUILD=0
    fi

    if [[ "$PARTIAL_BUILD" -eq 1 ]]; then
        if [[ "$ALLOW_PARTIAL_ROOTFS" -ne 1 ]]; then
            die "The rootfs did not validate cleanly and partial builds are disabled."
        fi
        log_warn "Continuing with a partial rootfs. The image will self-repair on the first native boot."
        return
    fi

    log_ok "Package state is clean and required runtime pieces are present"
}

configure_locale_timezone() {
    log_info "Configuring locale and timezone"

    printf '%s UTF-8\n' "$DEFAULT_LOCALE" > "$TARGET_ROOTFS/etc/locale.gen"
    printf 'LANG=%s\nLC_ALL=%s\n' "$DEFAULT_LOCALE" "$DEFAULT_LOCALE" > "$TARGET_ROOTFS/etc/default/locale"
    printf 'LANG=%s\nLC_ALL=%s\n' "$DEFAULT_LOCALE" "$DEFAULT_LOCALE" > "$TARGET_ROOTFS/etc/locale.conf"

    ln -snf "/usr/share/zoneinfo/$DEFAULT_TIMEZONE" "$TARGET_ROOTFS/etc/localtime"
    printf '%s\n' "$DEFAULT_TIMEZONE" > "$TARGET_ROOTFS/etc/timezone"

    if [[ "$PARTIAL_BUILD" -eq 0 ]]; then
        run_in_chroot "locale-gen '$DEFAULT_LOCALE'"
        run_in_chroot "update-locale LANG='$DEFAULT_LOCALE' LC_ALL='$DEFAULT_LOCALE'"
        run_in_chroot "dpkg-reconfigure --frontend=noninteractive tzdata"
    else
        log_warn "Locale generation and tzdata reconfigure are deferred to the first native boot."
    fi

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

configure_tpm_userspace() {
    log_info "Configuring TPM userspace access"

    run_in_chroot "getent group tss >/dev/null 2>&1 || groupadd --system tss"
    run_in_chroot "usermod -aG tss '$DEFAULT_USER' || true"

    mkdir -p "$TARGET_ROOTFS/etc/udev/rules.d"
    cat >"$TARGET_ROOTFS/etc/udev/rules.d/60-eaie-tpm.rules" <<'EOF'
# Allow members of the tss group to use TPM character devices.
KERNEL=="tpm[0-9]*", GROUP="tss", MODE="0660"
KERNEL=="tpmrm[0-9]*", GROUP="tss", MODE="0660"
EOF

    log_ok "TPM userspace access is configured"
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
    enable_rootfs_unit_if_present ssh.service

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

install_display_demo_assets() {
    log_info "Installing the EAIE display-demo assets"

    local wallpaper_source="$WORKSPACE/scripts/assets/screen.png"
    local script_source="$WORKSPACE/scripts/run-display-cycle-local.sh"
    local launcher_source="$WORKSPACE/scripts/assets/eaie-display-cycle.desktop"
    local demo_share_dir="$TARGET_ROOTFS/usr/local/share/eaie-display-cycle"
    local demo_wallpaper_target="/usr/local/share/eaie-display-cycle/screen.png"
    local demo_wallpaper="${demo_share_dir}/screen.png"
    local settings_file="$TARGET_ROOTFS/etc/xdg/pcmanfm-qt/lxqt/settings.conf"

    [[ -f "$wallpaper_source" ]] || die "Display-demo wallpaper is missing from the workspace: $wallpaper_source"
    [[ -f "$script_source" ]] || die "Board-local display-demo script is missing from the workspace: $script_source"
    [[ -f "$launcher_source" ]] || die "Display-demo desktop launcher is missing from the workspace: $launcher_source"

    install -Dm0755 "$script_source" \
        "$TARGET_ROOTFS/usr/local/bin/eaie-display-cycle"
    install -Dm0644 "$wallpaper_source" \
        "$demo_wallpaper"
    install -Dm0644 "$launcher_source" \
        "$TARGET_ROOTFS/usr/share/applications/eaie-display-cycle.desktop"

    mkdir -p "$(dirname "$settings_file")"
    if [[ ! -f "$settings_file" ]]; then
        cat >"$settings_file" <<EOF
[Desktop]
DesktopShortcuts=Home, Trash, Computer
Wallpaper=$demo_wallpaper_target
WallpaperMode=fit
WallpaperRandomize=false

[System]
Archiver=xarchiver
FallbackIconThemeName=oxygen
Terminal=qterminal

[Window]
AlwaysShowTabs=true
EOF
    else
        set_ini_key "$settings_file" "Desktop" "Wallpaper" "$demo_wallpaper_target"
        set_ini_key "$settings_file" "Desktop" "WallpaperMode" "fit"
        set_ini_key "$settings_file" "Desktop" "WallpaperRandomize" "false"
    fi

    log_ok "The display-demo runner, wallpaper, and launcher are installed into the image"
}

generate_initramfs_images() {
    log_info "Generating initramfs images for installed kernels"

    local versions version found=0
    versions="$(run_in_chroot "find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//'" || true)"

    [[ -n "$versions" ]] || die "No kernel images were found in /boot inside the rootfs."

    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        found=1
        if [[ -f "$TARGET_ROOTFS/boot/initrd.img-$version" ]]; then
            run_in_chroot "update-initramfs -u -k '$version'"
        else
            run_in_chroot "update-initramfs -c -k '$version'"
        fi
        [[ -f "$TARGET_ROOTFS/boot/initrd.img-$version" ]] || die "initramfs generation failed for kernel $version"
    done <<<"$versions"

    [[ "$found" -eq 1 ]] || die "No kernel versions were discovered for initramfs generation."
    update_boot_env_txt
    log_ok "initramfs images are present in /boot"
}

install_firstboot_repair_service() {
    log_info "Installing the native first-boot repair service"

    install -Dm0755 "$WORKSPACE/scripts/assets/firstboot-repair.sh" \
        "$TARGET_ROOTFS/usr/local/sbin/eaie-firstboot-repair.sh"
    install -Dm0644 "$WORKSPACE/scripts/assets/firstboot-repair.service" \
        "$TARGET_ROOTFS/etc/systemd/system/eaie-firstboot-repair.service"

    cat >"$TARGET_ROOTFS/etc/default/eaie-firstboot-repair" <<EOF
# Development-only first-boot repair settings.
DEFAULT_LOCALE='$DEFAULT_LOCALE'
DEFAULT_TIMEZONE='$DEFAULT_TIMEZONE'
DEFAULT_USER='$DEFAULT_USER'
DEFAULT_PASSWORD='$DEFAULT_PASSWORD'
REPAIR_PACKAGES='$REPAIR_PACKAGES'
EOF

    mkdir -p "$TARGET_ROOTFS${FIRSTBOOT_REPAIR_STATE_DIR}"
    if [[ "$PARTIAL_BUILD" -eq 1 ]]; then
        : > "$TARGET_ROOTFS${FIRSTBOOT_REPAIR_MARKER}"
    else
        rm -f "$TARGET_ROOTFS${FIRSTBOOT_REPAIR_MARKER}"
    fi

    enable_rootfs_unit eaie-firstboot-repair.service
    log_ok "The first-boot native repair service is installed"
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

create_ext4_image_with_progress() {
    local source_tree="$1"
    local image_path="$2"
    local fs_label="$3"
    local fs_uuid="$4"
    local fs_size="$5"
    local inode_count="${6:-}"
    local source_entries source_size_h
    local mkfs_cmd=(mkfs.ext4 -F -L "$fs_label" -U "$fs_uuid")
    local mount_dir=""
    local mount_succeeded=0

    [[ -d "$source_tree" ]] || die "Source tree for image creation is missing: $source_tree"

    source_entries="$(find "$source_tree" -mindepth 1 | wc -l | tr -d ' ')"
    source_size_h="$(du -sh "$source_tree" | awk '{print $1}')"

    log_info "Creating $image_path from $source_entries entries (${source_size_h})"

    rm -f "$image_path"

    if [[ -n "$inode_count" ]]; then
        mkfs_cmd+=(-N "$inode_count")
    fi
    mkfs_cmd+=("$image_path" "$fs_size")

    if "${mkfs_cmd[@]}"; then
        mount_dir="$(mktemp -d)"
        if mount -o loop "$image_path" "$mount_dir" 2>/dev/null; then
            mount_succeeded=1
            if rsync -aHAX --numeric-ids --info=progress2 "$source_tree/" "$mount_dir/"; then
                sync
                umount "$mount_dir"
                mount_succeeded=0
                rmdir "$mount_dir"
                return
            fi

            log_warn "Progress copy into $image_path failed; falling back to mke2fs -d"
            umount "$mount_dir" || true
            mount_succeeded=0
        else
            log_warn "Loop-mount population is unavailable; falling back to mke2fs -d for $image_path"
        fi

        [[ -n "$mount_dir" ]] && rmdir "$mount_dir" 2>/dev/null || true
    fi

    if [[ "$mount_succeeded" -eq 1 && -n "$mount_dir" ]]; then
        umount "$mount_dir" || true
        rmdir "$mount_dir" 2>/dev/null || true
    fi

    rm -f "$image_path"
    mkfs_cmd=(mke2fs -d "$source_tree" -L "$fs_label" -t ext4 -U "$fs_uuid")
    if [[ -n "$inode_count" ]]; then
        mkfs_cmd+=(-N "$inode_count")
    fi
    mkfs_cmd+=("$image_path" "$fs_size")

    "${mkfs_cmd[@]}"
}

image_contains_path() {
    local image_path="$1"
    local required_path="$2"

    debugfs -R "stat ${required_path}" "$image_path" >/dev/null 2>&1
}

verify_generated_partition_images() {
    local runtime_dtb_path="/spacemit/${PRIMARY_KERNEL_VERSION}/${BOARD_RUNTIME_DTB_NAME}.dtb"

    log_info "Validating generated partition images"

    [[ -n "$PRIMARY_KERNEL_VERSION" ]] || die "Primary kernel version is not known; cannot validate generated images."

    image_contains_path "bootfs.ext4" "/${BOARD_BOOT_ENV_NAME}" \
        || die "Generated bootfs.ext4 is missing /${BOARD_BOOT_ENV_NAME}"
    image_contains_path "bootfs.ext4" "/vmlinuz-${PRIMARY_KERNEL_VERSION}" \
        || die "Generated bootfs.ext4 is missing /vmlinuz-${PRIMARY_KERNEL_VERSION}"
    image_contains_path "bootfs.ext4" "/initrd.img-${PRIMARY_KERNEL_VERSION}" \
        || die "Generated bootfs.ext4 is missing /initrd.img-${PRIMARY_KERNEL_VERSION}"
    image_contains_path "bootfs.ext4" "$runtime_dtb_path" \
        || die "Generated bootfs.ext4 is missing ${runtime_dtb_path}"

    image_contains_path "rootfs.ext4" "/etc/os-release" \
        || die "Generated rootfs.ext4 is missing /etc/os-release"
    image_contains_path "rootfs.ext4" "/usr/lib/u-boot/spacemit/u-boot.itb" \
        || die "Generated rootfs.ext4 is missing /usr/lib/u-boot/spacemit/u-boot.itb"

    log_ok "Generated bootfs.ext4 and rootfs.ext4 passed sanity validation"
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
        find "$TARGET_ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | grep -q . || die "No initrd.img-* files were found in /boot; refusing to package a non-bootable image."
        rm -rf "$TARGET_BOOTFS"/*
        rsync -a "$TARGET_ROOTFS/boot/" "$TARGET_BOOTFS/"
        rm -rf "$TARGET_ROOTFS/boot/"*
    elif ! find "$TARGET_BOOTFS" -mindepth 1 -maxdepth 1 | read -r _; then
        die "Neither $TARGET_ROOTFS/boot nor $TARGET_BOOTFS contain boot files."
    else
        log_warn "Reusing existing $TARGET_BOOTFS contents because $TARGET_ROOTFS/boot is already empty"
    fi

    rm -f bootfs.ext4 rootfs.ext4
    create_ext4_image_with_progress "$TARGET_BOOTFS" "bootfs.ext4" "bootfs" "$uuid_bootfs" "256M"
    create_ext4_image_with_progress "$TARGET_ROOTFS" "rootfs.ext4" "rootfs" "$uuid_rootfs" "$ROOTFS_SIZE" "524288"
    verify_generated_partition_images

    log_ok "bootfs.ext4 and rootfs.ext4 were generated"
}

prepare_pack_dir() {
    log_info "Preparing image packaging inputs"

    mkdir -p "$PACK_DIR/factory"

    local required_boot_artifacts=(
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_emmc.bin"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_sd.bin"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_spinand.bin"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/bootinfo_spinor.bin"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/FSBL.bin"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/u-boot.itb"
        "$TARGET_ROOTFS/usr/lib/u-boot/spacemit/env.bin"
        "$TARGET_ROOTFS/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.itb"
    )
    local artifact
    for artifact in "${required_boot_artifacts[@]}"; do
        [[ -f "$artifact" ]] || die "Required boot artifact is missing from the rootfs: $artifact"
    done

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
    local pack_entries pack_size_h archive_name
    archive_name="${IMAGE_PREFIX}.zip"
    log_info "Packaging ${COLOR_YELLOW}${archive_name}${COLOR_RESET}"
    pack_entries="$(find "$PACK_DIR" -mindepth 1 | wc -l | tr -d ' ')"
    pack_size_h="$(du -sh "$PACK_DIR" | awk '{print $1}')"
    log_info "Creating ${COLOR_YELLOW}${archive_name}${COLOR_RESET} from $pack_entries entries (${pack_size_h})"
    rm -f "$archive_name"
    (
        cd "$PACK_DIR"
        zip -r -dg -db "../${archive_name}" .
    )
    [[ -f "$archive_name" ]] || die "Expected ${archive_name} was not created"
    log_ok "${archive_name} created"
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

    if [[ "$PARTIAL_BUILD" -eq 1 ]]; then
        log_warn "Skipping apt cache cleanup so the first native boot can reuse downloaded packages"
        return
    fi

    run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get clean"
}

finalize_rootfs_for_packaging() {
    cleanup_rootfs_caches
    umount_rootfs
    prepare_fstab_and_partition_images
}

main() {
    BUILD_START_EPOCH="$(now_millis)"
    validate_build_modes
    compose_package_sets
    run_timed_phase "Install container build tools" install_container_tools
    run_timed_phase "Prepare rootfs staging tree" prepare_rootfs_tree
    run_timed_phase "Mount rootfs and configure apt sources" prepare_chroot_environment
    run_timed_phase "Install rootfs packages" install_rootfs_packages
    run_timed_phase "Repair and validate package state" repair_and_validate_packages
    run_timed_phase "Apply source-built BSP overlays" apply_source_package_overlays
    run_timed_phase "Configure locale and timezone" configure_locale_timezone
    run_timed_phase "Configure development users" configure_users
    run_timed_phase "Configure TPM userspace access" configure_tpm_userspace
    run_timed_phase "Configure NetworkManager" configure_network
    run_timed_phase "Enable SSH" configure_ssh
    run_timed_phase "Configure LXQt Wayland autologin" configure_sddm_autologin
    run_timed_phase "Install display-demo assets" install_display_demo_assets
    run_timed_phase "Install first-boot repair service" install_firstboot_repair_service
    run_timed_phase "Install rootfs auto-expand service" install_rootfs_expand_service
    run_timed_phase "Generate initramfs images" generate_initramfs_images
    run_timed_phase "Finalize rootfs and generate ext4 images" finalize_rootfs_for_packaging
    run_timed_phase "Prepare packaging inputs" prepare_pack_dir
    run_timed_phase "Package Titan flash zip" package_titan_zip
    run_timed_phase "Package SD card image" package_sdcard_image
    print_timing_summary "$(( $(now_millis) - BUILD_START_EPOCH ))"
}

main "$@"
