#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

KERNEL_DEB_PATH=""
KERNEL_VERSION=""
LOCAL_KERNEL_IMAGE=""
LOCAL_SOURCE_DTB=""
LOCAL_KERNEL_HASH=""
LOCAL_RUNTIME_DTB_HASH=""
REMOTE_HOME=""
REMOTE_STAGE_DIR=""
REMOTE_DEB_PATH=""
REMOTE_DTB_PATH=""
WORK_DIR=""
REMOTE_SCRIPT_FILE=""

usage() {
    cat <<'EOF'
Usage: bash scripts/deploy-live-kernel.sh [NAME=VALUE ...]

Reuses or rebuilds the source kernel Debian package, deploys it to a live
board over SSH, extracts it directly onto the live root filesystem,
synchronizes the selected board DTB into /boot, and optionally reboots the
board for validation.

Defaults are loaded from:
  build.conf

Useful overrides:
  BOARD=<name>
  BOARD_HOST=<addr>
  BOARD_USER=<name>
  BOARD_PASS=<pass>
  BOARD_SSH_PORT=<port>
  KERNEL_REBUILD=yes|no
  AUTO_REBOOT=yes|no
  SOURCE_ORIGIN=upstream|custom
  KERNEL_SOURCE_URL=<git-url>
  KERNEL_SOURCE_REF=<git-ref>
  EAIE_CUSTOM_KERNEL_SOURCE_URL=<git-url>
  EAIE_CUSTOM_KERNEL_SOURCE_REF=<git-ref>

Examples:
  bash scripts/deploy-live-kernel.sh
  bash scripts/deploy-live-kernel.sh KERNEL_REBUILD=yes
  bash scripts/deploy-live-kernel.sh BOARD=bpi-f3 AUTO_REBOOT=no
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ -n "$REMOTE_SCRIPT_FILE" && -f "$REMOTE_SCRIPT_FILE" ]]; then
        rm -f "$REMOTE_SCRIPT_FILE"
    fi
}

trap cleanup EXIT

parse_args() {
    local overrides=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *=*)
                overrides+=("$1")
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done

    parse_kv_overrides "${overrides[@]}"
}

prepare_kernel_package() {
    log_info "Resolving the source kernel package"

    ARTIFACT_ENV_FILE="$SOURCE_ARTIFACT_ENV_FILE" \
    KERNEL_MODE=source \
    UBOOT_MODE=default \
    KERNEL_REBUILD="$KERNEL_REBUILD" \
    UBOOT_REBUILD=no \
    KERNEL_SOURCE_URL="$KERNEL_SOURCE_URL" \
    KERNEL_SOURCE_REF="$KERNEL_SOURCE_REF" \
    UBOOT_SOURCE_URL="$UBOOT_SOURCE_URL" \
    UBOOT_SOURCE_REF="$UBOOT_SOURCE_REF" \
        bash "$ROOT_DIR/scripts/build-source-artifacts.sh"

    # shellcheck disable=SC1090
    source "$SOURCE_ARTIFACT_ENV_FILE"

    [[ -n "${KERNEL_SOURCE_DEB:-}" ]] || die "No kernel package path was produced by scripts/build-source-artifacts.sh"
    KERNEL_DEB_PATH="$ROOT_DIR/$KERNEL_SOURCE_DEB"
    [[ -f "$KERNEL_DEB_PATH" ]] || die "Kernel package not found: $KERNEL_DEB_PATH"
    log_ok "Kernel package selected: $KERNEL_DEB_PATH"
}

extract_kernel_package() {
    local kernel_image_name=""

    WORK_DIR="$(mktemp -d)"
    dpkg-deb -x "$KERNEL_DEB_PATH" "$WORK_DIR/pkg"

    kernel_image_name="$(find "$WORK_DIR/pkg/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -n 1)"
    [[ -n "$kernel_image_name" ]] || die "Could not determine the kernel version from $KERNEL_DEB_PATH"

    KERNEL_VERSION="${kernel_image_name#vmlinuz-}"
    LOCAL_KERNEL_IMAGE="$WORK_DIR/pkg/boot/vmlinuz-$KERNEL_VERSION"
    LOCAL_SOURCE_DTB="$WORK_DIR/pkg/usr/lib/linux-image-$KERNEL_VERSION/spacemit/$BOARD_SOURCE_DTB_NAME.dtb"

    [[ -f "$LOCAL_KERNEL_IMAGE" ]] || die "Extracted kernel image is missing: $LOCAL_KERNEL_IMAGE"
    [[ -f "$LOCAL_SOURCE_DTB" ]] || die "Extracted board DTB is missing: $LOCAL_SOURCE_DTB"

    LOCAL_KERNEL_HASH="$(sha256sum "$LOCAL_KERNEL_IMAGE" | awk '{print $1}')"
    LOCAL_RUNTIME_DTB_HASH="$(sha256sum "$LOCAL_SOURCE_DTB" | awk '{print $1}')"

    log_ok "Kernel package contains kernel $KERNEL_VERSION"
}

stage_remote_files() {
    local remote_deb_name

    REMOTE_HOME="$(get_remote_home)"
    [[ -n "$REMOTE_HOME" ]] || die "Could not determine the remote home directory for ${BOARD_USER}@${BOARD_HOST}"

    REMOTE_STAGE_DIR="$REMOTE_HOME/.cache/eaie-live-deploy/kernel"
    board_ssh "mkdir -p '$REMOTE_STAGE_DIR'"

    remote_deb_name="$(basename "$KERNEL_DEB_PATH")"
    REMOTE_DEB_PATH="$REMOTE_STAGE_DIR/$remote_deb_name"
    REMOTE_DTB_PATH="$REMOTE_STAGE_DIR/$BOARD_SOURCE_DTB_NAME.dtb"

    log_info "Copying the kernel package to the board"
    board_scp_to "$KERNEL_DEB_PATH" "$REMOTE_DEB_PATH"

    log_info "Copying the board DTB to the board"
    board_scp_to "$LOCAL_SOURCE_DTB" "$REMOTE_DTB_PATH"
}

install_remote_kernel() {
    REMOTE_SCRIPT_FILE="$(mktemp)"
    cat >"$REMOTE_SCRIPT_FILE" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

REMOTE_DEB_PATH="$1"
REMOTE_DTB_PATH="$2"
KERNEL_VERSION="$3"
BOARD_SOURCE_DTB_NAME="$4"
BOARD_RUNTIME_DTB_NAME="$5"
BOARD_BOOT_ENV_NAME="$6"
UNPACK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$UNPACK_DIR"
}

trap cleanup EXIT

command -v rsync >/dev/null 2>&1 || {
    echo "rsync is required on the board for live kernel deploy" >&2
    exit 1
}

dpkg-deb -x "$REMOTE_DEB_PATH" "$UNPACK_DIR"

[[ -d "$UNPACK_DIR/boot" ]] && rsync -a "$UNPACK_DIR/boot/" /boot/
[[ -d "$UNPACK_DIR/etc" ]] && rsync -a "$UNPACK_DIR/etc/" /etc/
[[ -d "$UNPACK_DIR/lib" ]] && rsync -a "$UNPACK_DIR/lib/" /lib/
[[ -d "$UNPACK_DIR/usr" ]] && rsync -a "$UNPACK_DIR/usr/" /usr/

mkdir -p "/usr/lib/linux-image-$KERNEL_VERSION/spacemit"
mkdir -p "/boot/spacemit/$KERNEL_VERSION"

install -m 0644 "$REMOTE_DTB_PATH" "/usr/lib/linux-image-$KERNEL_VERSION/spacemit/$BOARD_SOURCE_DTB_NAME.dtb"
install -m 0644 "$REMOTE_DTB_PATH" "/boot/spacemit/$KERNEL_VERSION/$BOARD_SOURCE_DTB_NAME.dtb"

if [[ "$BOARD_SOURCE_DTB_NAME" != "$BOARD_RUNTIME_DTB_NAME" ]]; then
    cp -f "/usr/lib/linux-image-$KERNEL_VERSION/spacemit/$BOARD_SOURCE_DTB_NAME.dtb" \
        "/usr/lib/linux-image-$KERNEL_VERSION/spacemit/$BOARD_RUNTIME_DTB_NAME.dtb"
    cp -f "/boot/spacemit/$KERNEL_VERSION/$BOARD_SOURCE_DTB_NAME.dtb" \
        "/boot/spacemit/$KERNEL_VERSION/$BOARD_RUNTIME_DTB_NAME.dtb"
fi

depmod "$KERNEL_VERSION" || true
if [[ -f "/boot/initrd.img-$KERNEL_VERSION" ]]; then
    update-initramfs -u -k "$KERNEL_VERSION"
else
    update-initramfs -c -k "$KERNEL_VERSION"
fi

cat >"/boot/$BOARD_BOOT_ENV_NAME" <<BOOT_ENV
knl_name=vmlinuz-$KERNEL_VERSION
ramdisk_name=initrd.img-$KERNEL_VERSION
dtb_dir=spacemit/$KERNEL_VERSION
BOOT_ENV

sync
EOF

    log_info "Extracting the kernel package onto the board"
    run_board_root_script_file \
        "$REMOTE_SCRIPT_FILE" \
        "$REMOTE_DEB_PATH" \
        "$REMOTE_DTB_PATH" \
        "$KERNEL_VERSION" \
        "$BOARD_SOURCE_DTB_NAME" \
        "$BOARD_RUNTIME_DTB_NAME" \
        "$BOARD_BOOT_ENV_NAME"

    log_ok "Kernel payload and DTB were staged onto the board"
}

validate_remote_payloads() {
    local remote_kernel_hash remote_runtime_dtb_hash

    remote_kernel_hash="$(board_ssh "sha256sum '/boot/vmlinuz-$KERNEL_VERSION' | awk '{print \$1}'")"
    remote_runtime_dtb_hash="$(board_ssh "sha256sum '/boot/spacemit/$KERNEL_VERSION/$BOARD_RUNTIME_DTB_NAME.dtb' | awk '{print \$1}'")"

    [[ "$remote_kernel_hash" == "$LOCAL_KERNEL_HASH" ]] \
        || die "Remote /boot/vmlinuz-$KERNEL_VERSION hash does not match the selected kernel package"
    [[ "$remote_runtime_dtb_hash" == "$LOCAL_RUNTIME_DTB_HASH" ]] \
        || die "Remote runtime DTB hash does not match the selected board DTB"

    log_ok "Remote /boot payloads match the selected kernel package"
}

print_runtime_state() {
    printf '\n'
    printf '%s[INFO]%s Runtime checks on %s@%s\n' "$COLOR_BLUE" "$COLOR_RESET" "$BOARD_USER" "$BOARD_HOST"
    printf '  uname -a: %s\n' "$(board_ssh 'uname -a')"
    printf '  /proc/device-tree/model: %s\n' "$(board_ssh "tr -d '\\000' < /proc/device-tree/model")"
    printf '  /boot/%s:\n' "$BOARD_BOOT_ENV_NAME"
    board_ssh "sed -n '1,20p' '/boot/$BOARD_BOOT_ENV_NAME'"
}

main() {
    load_build_config
    parse_args "$@"
    finalize_deploy_settings

    require_host_tools ssh scp bash dpkg-deb sha256sum awk find sort mktemp
    ensure_board_access

    log_info "Selected board profile: $BOARD_PROFILE ($BOARD_DESCRIPTION)"
    log_info "Deploy target: ${BOARD_USER}@${BOARD_HOST}:${BOARD_SSH_PORT}"
    log_info "Kernel source remote: $(format_source_with_ref "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_REF")"
    log_info "Kernel package rebuild requested: $KERNEL_REBUILD"

    prepare_kernel_package
    extract_kernel_package
    stage_remote_files
    install_remote_kernel
    validate_remote_payloads

    if [[ "$AUTO_REBOOT" == "yes" ]]; then
        reboot_and_wait
        validate_remote_payloads
        print_runtime_state
        return
    fi

    log_warn "AUTO_REBOOT=no, so the board was not rebooted. Reboot it manually before runtime validation."
}

main "$@"
