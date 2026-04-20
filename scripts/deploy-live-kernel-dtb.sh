#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

REMOTE_HOME=""
REMOTE_STAGE_DIR=""
REMOTE_DTB_PATH=""
REMOTE_KERNEL_VERSION=""
LOCAL_DTB_PATH=""
LOCAL_DTB_HASH=""
WORK_DIR=""
REMOTE_SCRIPT_FILE=""

usage() {
    cat <<'EOF'
Usage: bash scripts/deploy-live-kernel-dtb.sh [NAME=VALUE ...]

Builds only the selected board DTB from the kernel source tree, copies it to a
live board over SSH, updates both the source DTB name and the runtime alias in
/boot and /usr/lib, and optionally reboots for validation.

Defaults are loaded from:
  build.conf

Useful overrides:
  BOARD=<name>
  BOARD_HOST=<addr>
  BOARD_USER=<name>
  BOARD_PASS=<pass>
  BOARD_SSH_PORT=<port>
  AUTO_REBOOT=yes|no
  SOURCE_ORIGIN=upstream|custom
  KERNEL_SOURCE_URL=<git-url>
  KERNEL_SOURCE_REF=<git-ref>
  EAIE_CUSTOM_KERNEL_SOURCE_URL=<git-url>
  EAIE_CUSTOM_KERNEL_SOURCE_REF=<git-ref>

Examples:
  bash scripts/deploy-live-kernel-dtb.sh
  bash scripts/deploy-live-kernel-dtb.sh AUTO_REBOOT=no
  bash scripts/deploy-live-kernel-dtb.sh BOARD=bpi-f3
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

build_kernel_dtb() {
    local dtb_target="spacemit/${BOARD_SOURCE_DTB_NAME}.dtb"

    prepare_kernel_source_tree

    log_info "Building kernel DTB target $dtb_target"
    (
        cd "$KERNEL_SOURCE_DIR"
        export PATH="$TOOLCHAIN_BIN_DIR:$PATH"
        export ARCH="$ARCH"
        export CROSS_COMPILE="$CROSS_COMPILE_PREFIX"

        if [[ -f .config ]]; then
            make olddefconfig
        else
            make k1_defconfig
        fi

        make -j"$MAKE_JOBS" "$dtb_target"
    )

    LOCAL_DTB_PATH="$KERNEL_SOURCE_DIR/arch/riscv/boot/dts/spacemit/${BOARD_SOURCE_DTB_NAME}.dtb"
    [[ -f "$LOCAL_DTB_PATH" ]] || die "The built DTB is missing: $LOCAL_DTB_PATH"

    LOCAL_DTB_HASH="$(sha256sum "$LOCAL_DTB_PATH" | awk '{print $1}')"
    log_ok "Kernel DTB build is ready: $LOCAL_DTB_PATH"
}

stage_remote_dtb() {
    REMOTE_HOME="$(get_remote_home)"
    [[ -n "$REMOTE_HOME" ]] || die "Could not determine the remote home directory for ${BOARD_USER}@${BOARD_HOST}"

    REMOTE_KERNEL_VERSION="$(board_ssh 'uname -r')"
    [[ -n "$REMOTE_KERNEL_VERSION" ]] || die "Could not determine the remote kernel version"

    REMOTE_STAGE_DIR="$REMOTE_HOME/.cache/eaie-live-deploy/dtb"
    REMOTE_DTB_PATH="$REMOTE_STAGE_DIR/$BOARD_SOURCE_DTB_NAME.dtb"

    board_ssh "mkdir -p '$REMOTE_STAGE_DIR'"

    log_info "Copying the rebuilt DTB to the board"
    board_scp_to "$LOCAL_DTB_PATH" "$REMOTE_DTB_PATH"
}

install_remote_dtb() {
    REMOTE_SCRIPT_FILE="$(mktemp)"
    cat >"$REMOTE_SCRIPT_FILE" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

REMOTE_DTB_PATH="$1"
REMOTE_KERNEL_VERSION="$2"
BOARD_SOURCE_DTB_NAME="$3"
BOARD_RUNTIME_DTB_NAME="$4"

mkdir -p "/usr/lib/linux-image-$REMOTE_KERNEL_VERSION/spacemit"
mkdir -p "/boot/spacemit/$REMOTE_KERNEL_VERSION"

install -m 0644 "$REMOTE_DTB_PATH" "/usr/lib/linux-image-$REMOTE_KERNEL_VERSION/spacemit/$BOARD_SOURCE_DTB_NAME.dtb"
install -m 0644 "$REMOTE_DTB_PATH" "/boot/spacemit/$REMOTE_KERNEL_VERSION/$BOARD_SOURCE_DTB_NAME.dtb"

if [[ "$BOARD_SOURCE_DTB_NAME" != "$BOARD_RUNTIME_DTB_NAME" ]]; then
    cp -f "/usr/lib/linux-image-$REMOTE_KERNEL_VERSION/spacemit/$BOARD_SOURCE_DTB_NAME.dtb" \
        "/usr/lib/linux-image-$REMOTE_KERNEL_VERSION/spacemit/$BOARD_RUNTIME_DTB_NAME.dtb"
    cp -f "/boot/spacemit/$REMOTE_KERNEL_VERSION/$BOARD_SOURCE_DTB_NAME.dtb" \
        "/boot/spacemit/$REMOTE_KERNEL_VERSION/$BOARD_RUNTIME_DTB_NAME.dtb"
fi

sync
EOF

    log_info "Installing the rebuilt DTB on the board"
    run_board_root_script_file \
        "$REMOTE_SCRIPT_FILE" \
        "$REMOTE_DTB_PATH" \
        "$REMOTE_KERNEL_VERSION" \
        "$BOARD_SOURCE_DTB_NAME" \
        "$BOARD_RUNTIME_DTB_NAME"

    log_ok "Board DTB files were updated on the board"
}

validate_remote_dtb() {
    local remote_runtime_hash remote_source_hash

    remote_source_hash="$(board_ssh "sha256sum '/boot/spacemit/$REMOTE_KERNEL_VERSION/$BOARD_SOURCE_DTB_NAME.dtb' | awk '{print \$1}'")"
    remote_runtime_hash="$(board_ssh "sha256sum '/boot/spacemit/$REMOTE_KERNEL_VERSION/$BOARD_RUNTIME_DTB_NAME.dtb' | awk '{print \$1}'")"

    [[ "$remote_source_hash" == "$LOCAL_DTB_HASH" ]] \
        || die "Remote source DTB hash does not match the rebuilt kernel DTB"
    [[ "$remote_runtime_hash" == "$LOCAL_DTB_HASH" ]] \
        || die "Remote runtime DTB hash does not match the rebuilt kernel DTB"

    log_ok "Remote DTB payloads match the rebuilt kernel DTB"
}

print_runtime_state() {
    printf '\n'
    printf '%s[INFO]%s Runtime checks on %s@%s\n' "$COLOR_BLUE" "$COLOR_RESET" "$BOARD_USER" "$BOARD_HOST"
    printf '  uname -a: %s\n' "$(board_ssh 'uname -a')"
    printf '  /proc/device-tree/model: %s\n' "$(board_ssh "tr -d '\\000' < /proc/device-tree/model")"
}

main() {
    load_build_config
    parse_args "$@"
    finalize_deploy_settings

    require_host_tools ssh scp bash git curl tar make sha256sum awk find sort mktemp
    ensure_board_access

    log_info "Selected board profile: $BOARD_PROFILE ($BOARD_DESCRIPTION)"
    log_info "Deploy target: ${BOARD_USER}@${BOARD_HOST}:${BOARD_SSH_PORT}"
    log_info "Kernel source remote: $(format_source_with_ref "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_REF")"

    build_kernel_dtb
    stage_remote_dtb
    install_remote_dtb
    validate_remote_dtb

    if [[ "$AUTO_REBOOT" == "yes" ]]; then
        reboot_and_wait
        validate_remote_dtb
        print_runtime_state
        return
    fi

    log_warn "AUTO_REBOOT=no, so the board was not rebooted. Reboot it manually before runtime validation."
}

main "$@"
