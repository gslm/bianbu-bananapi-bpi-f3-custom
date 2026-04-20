#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_CONF_FILE="${BUILD_CONF_FILE:-$ROOT_DIR/build.conf}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.bianbu-build}"
SOURCE_ARTIFACT_ENV_FILE="${SOURCE_ARTIFACT_ENV_FILE:-$STATE_DIR/source-artifacts.env}"
SOURCES_DIR="${SOURCES_DIR:-$ROOT_DIR/sources}"

DEFAULT_KERNEL_SOURCE_URL="https://gitee.com/bianbu-linux/linux-6.6.git"
DEFAULT_UBOOT_SOURCE_URL="https://gitee.com/bianbu-linux/uboot-2022.10.git"

BOARD="${BOARD:-eaie-v1-riscv-spacemitk1}"
BOARD_HOST="${BOARD_HOST:-192.168.28.85}"
BOARD_USER="${BOARD_USER:-eaie}"
BOARD_PASS="${BOARD_PASS:-eaie}"
BOARD_SSH_PORT="${BOARD_SSH_PORT:-22}"
AUTO_REBOOT="${AUTO_REBOOT:-yes}"
FASTBOOT_BIN="${FASTBOOT_BIN:-fastboot}"
KERNEL_REBUILD="${KERNEL_REBUILD:-no}"
UBOOT_REBUILD="${UBOOT_REBUILD:-no}"
SOURCE_ORIGIN="${SOURCE_ORIGIN:-upstream}"
KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-}"
KERNEL_SOURCE_REF="${KERNEL_SOURCE_REF:-}"
UBOOT_SOURCE_URL="${UBOOT_SOURCE_URL:-}"
UBOOT_SOURCE_REF="${UBOOT_SOURCE_REF:-}"
EAIE_CUSTOM_KERNEL_SOURCE_URL="${EAIE_CUSTOM_KERNEL_SOURCE_URL:-}"
EAIE_CUSTOM_KERNEL_SOURCE_REF="${EAIE_CUSTOM_KERNEL_SOURCE_REF:-}"
EAIE_CUSTOM_UBOOT_SOURCE_URL="${EAIE_CUSTOM_UBOOT_SOURCE_URL:-}"
EAIE_CUSTOM_UBOOT_SOURCE_REF="${EAIE_CUSTOM_UBOOT_SOURCE_REF:-}"

KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR:-$SOURCES_DIR/kernel/linux-6.6}"
UBOOT_SOURCE_DIR="${UBOOT_SOURCE_DIR:-$SOURCES_DIR/u-boot/uboot-2022.10}"

TOOLCHAIN_VERSION="${TOOLCHAIN_VERSION:-spacemit-toolchain-linux-glibc-x86_64-v1.0.0}"
TOOLCHAIN_ARCHIVE="${TOOLCHAIN_VERSION}.tar.xz"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://archive.spacemit.com/toolchain/${TOOLCHAIN_ARCHIVE}}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$SOURCES_DIR/toolchains/$TOOLCHAIN_VERSION}"
TOOLCHAIN_BIN_DIR="$TOOLCHAIN_DIR/bin"

ARCH="${ARCH:-riscv}"
CROSS_COMPILE_PREFIX="${CROSS_COMPILE_PREFIX:-riscv64-unknown-linux-gnu-}"
MAKE_JOBS="${MAKE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

BOARD_PROFILE=""
BOARD_DESCRIPTION=""
BOARD_SOURCE_DTB_NAME=""
BOARD_RUNTIME_DTB_NAME=""
BOARD_BOOT_ENV_NAME=""
REMOTE_SUDO_MODE=""

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'
COLOR_MAGENTA=$'\033[1;35m'

declare -a BOARD_SSH_BASE=()
declare -a BOARD_SCP_BASE=()

log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_ok() {
    printf '%s[ OK ]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

log_error() {
    printf '%s[ERR ]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

normalize_yes_no() {
    local value="${1:-}"
    local setting_name="$2"

    case "${value,,}" in
        yes|true|1)
            printf 'yes\n'
            ;;
        no|false|0|'')
            printf 'no\n'
            ;;
        *)
            die "$setting_name must be yes or no, got: $value"
            ;;
    esac
}

format_source_with_ref() {
    local url="$1"
    local ref="${2:-}"

    if [[ -n "$ref" ]]; then
        printf '%s @ %s\n' "$url" "$ref"
        return
    fi

    printf '%s\n' "$url"
}

load_build_config() {
    if [[ ! -f "$BUILD_CONF_FILE" ]]; then
        log_warn "No build.conf was found at $BUILD_CONF_FILE; using built-in defaults"
        return
    fi

    # shellcheck disable=SC1090
    source "$BUILD_CONF_FILE"
}

apply_common_setting() {
    local key="$1"
    local value="$2"

    case "$key" in
        BOARD) BOARD="$value" ;;
        BOARD_HOST) BOARD_HOST="$value" ;;
        BOARD_USER) BOARD_USER="$value" ;;
        BOARD_PASS) BOARD_PASS="$value" ;;
        BOARD_SSH_PORT) BOARD_SSH_PORT="$value" ;;
        AUTO_REBOOT) AUTO_REBOOT="$value" ;;
        FASTBOOT_BIN) FASTBOOT_BIN="$value" ;;
        KERNEL_REBUILD) KERNEL_REBUILD="$value" ;;
        UBOOT_REBUILD) UBOOT_REBUILD="$value" ;;
        SOURCE_ORIGIN) SOURCE_ORIGIN="$value" ;;
        KERNEL_SOURCE_URL) KERNEL_SOURCE_URL="$value" ;;
        KERNEL_SOURCE_REF) KERNEL_SOURCE_REF="$value" ;;
        UBOOT_SOURCE_URL) UBOOT_SOURCE_URL="$value" ;;
        UBOOT_SOURCE_REF) UBOOT_SOURCE_REF="$value" ;;
        EAIE_CUSTOM_KERNEL_SOURCE_URL) EAIE_CUSTOM_KERNEL_SOURCE_URL="$value" ;;
        EAIE_CUSTOM_KERNEL_SOURCE_REF) EAIE_CUSTOM_KERNEL_SOURCE_REF="$value" ;;
        EAIE_CUSTOM_UBOOT_SOURCE_URL) EAIE_CUSTOM_UBOOT_SOURCE_URL="$value" ;;
        EAIE_CUSTOM_UBOOT_SOURCE_REF) EAIE_CUSTOM_UBOOT_SOURCE_REF="$value" ;;
        MAKE_JOBS) MAKE_JOBS="$value" ;;
        *)
            die "Unknown deploy setting: $key"
            ;;
    esac
}

parse_kv_overrides() {
    local arg key value

    for arg in "$@"; do
        [[ "$arg" == *=* ]] || die "Unsupported argument: $arg. Use KEY=VALUE overrides."
        key="${arg%%=*}"
        value="${arg#*=}"
        apply_common_setting "$key" "$value"
    done
}

resolve_source_origin() {
    case "$SOURCE_ORIGIN" in
        upstream|default)
            SOURCE_ORIGIN="upstream"
            [[ -n "$KERNEL_SOURCE_URL" ]] || KERNEL_SOURCE_URL="$DEFAULT_KERNEL_SOURCE_URL"
            [[ -n "$UBOOT_SOURCE_URL" ]] || UBOOT_SOURCE_URL="$DEFAULT_UBOOT_SOURCE_URL"
            ;;
        custom|bitbucket)
            SOURCE_ORIGIN="custom"
            [[ -n "$KERNEL_SOURCE_URL" ]] || KERNEL_SOURCE_URL="$EAIE_CUSTOM_KERNEL_SOURCE_URL"
            [[ -n "$KERNEL_SOURCE_REF" ]] || KERNEL_SOURCE_REF="$EAIE_CUSTOM_KERNEL_SOURCE_REF"
            [[ -n "$UBOOT_SOURCE_URL" ]] || UBOOT_SOURCE_URL="$EAIE_CUSTOM_UBOOT_SOURCE_URL"
            [[ -n "$UBOOT_SOURCE_REF" ]] || UBOOT_SOURCE_REF="$EAIE_CUSTOM_UBOOT_SOURCE_REF"
            [[ -n "$KERNEL_SOURCE_URL" ]] || die "SOURCE_ORIGIN=custom requires EAIE_CUSTOM_KERNEL_SOURCE_URL or KERNEL_SOURCE_URL"
            [[ -n "$UBOOT_SOURCE_URL" ]] || die "SOURCE_ORIGIN=custom requires EAIE_CUSTOM_UBOOT_SOURCE_URL or UBOOT_SOURCE_URL"
            ;;
        *)
            die "Unsupported source origin: $SOURCE_ORIGIN"
            ;;
    esac
}

resolve_board_profile() {
    BOARD_PROFILE="$BOARD"

    case "$BOARD_PROFILE" in
        bpi-f3)
            BOARD_DESCRIPTION="Banana Pi BPI-F3 baseline"
            BOARD_SOURCE_DTB_NAME="k1-x_deb1"
            BOARD_RUNTIME_DTB_NAME="k1-x_deb1"
            BOARD_BOOT_ENV_NAME="env_k1-x.txt"
            ;;
        eaie-v1-riscv-spacemitk1)
            BOARD_DESCRIPTION="EAIE v1 custom board profile"
            BOARD_SOURCE_DTB_NAME="k1-x_eaie-v1-riscv-spacemitk1"
            BOARD_RUNTIME_DTB_NAME="k1-x_deb1"
            BOARD_BOOT_ENV_NAME="env_k1-x.txt"
            ;;
        *)
            die "Unsupported board profile: $BOARD_PROFILE"
            ;;
    esac
}

build_remote_commands() {
    BOARD_SSH_BASE=(ssh -p "$BOARD_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
    BOARD_SCP_BASE=(scp -P "$BOARD_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

    if [[ -n "$BOARD_PASS" ]]; then
        BOARD_SSH_BASE=(sshpass -p "$BOARD_PASS" "${BOARD_SSH_BASE[@]}")
        BOARD_SCP_BASE=(sshpass -p "$BOARD_PASS" "${BOARD_SCP_BASE[@]}")
    fi
}

finalize_deploy_settings() {
    KERNEL_REBUILD="$(normalize_yes_no "$KERNEL_REBUILD" "KERNEL_REBUILD")"
    UBOOT_REBUILD="$(normalize_yes_no "$UBOOT_REBUILD" "UBOOT_REBUILD")"
    AUTO_REBOOT="$(normalize_yes_no "$AUTO_REBOOT" "AUTO_REBOOT")"

    [[ -n "$BOARD_HOST" ]] || die "BOARD_HOST must not be empty"
    [[ -n "$BOARD_USER" ]] || die "BOARD_USER must not be empty"
    [[ "$BOARD_SSH_PORT" =~ ^[0-9]+$ ]] || die "BOARD_SSH_PORT must be numeric"

    resolve_source_origin
    resolve_board_profile
    build_remote_commands
}

shell_join_args() {
    local arg

    for arg in "$@"; do
        printf '%q ' "$arg"
    done
}

board_ssh() {
    "${BOARD_SSH_BASE[@]}" "${BOARD_USER}@${BOARD_HOST}" "$@"
}

board_scp_to() {
    local local_path="$1"
    local remote_path="$2"

    "${BOARD_SCP_BASE[@]}" "$local_path" "${BOARD_USER}@${BOARD_HOST}:$remote_path"
}

detect_remote_sudo_mode() {
    local quoted_pass

    if [[ -n "$REMOTE_SUDO_MODE" ]]; then
        return
    fi

    if board_ssh "sudo -n true" >/dev/null 2>&1; then
        REMOTE_SUDO_MODE="nopass"
        return
    fi

    [[ -n "$BOARD_PASS" ]] || die "Remote sudo requires BOARD_PASS or passwordless sudo on ${BOARD_USER}@${BOARD_HOST}"

    quoted_pass="$(printf %q "$BOARD_PASS")"
    if board_ssh "printf '%s\n' $quoted_pass | sudo -S -p '' true" >/dev/null 2>&1; then
        REMOTE_SUDO_MODE="password"
        return
    fi

    die "Could not validate sudo access on ${BOARD_USER}@${BOARD_HOST}"
}

run_board_script_file() {
    local script_file="$1"
    shift

    board_ssh bash -s -- "$@" < "$script_file"
}

run_board_root_script_file() {
    local script_file="$1"
    local remote_args
    shift

    detect_remote_sudo_mode
    remote_args="$(shell_join_args "$@")"

    if [[ "$REMOTE_SUDO_MODE" == "nopass" ]]; then
        "${BOARD_SSH_BASE[@]}" "${BOARD_USER}@${BOARD_HOST}" "sudo bash -s -- $remote_args" < "$script_file"
        return
    fi

    {
        printf '%s\n' "$BOARD_PASS"
        cat "$script_file"
    } | "${BOARD_SSH_BASE[@]}" "${BOARD_USER}@${BOARD_HOST}" "sudo -S -p '' bash -s -- $remote_args"
}

run_board_root_command() {
    local command="$1"
    local quoted_command quoted_pass

    detect_remote_sudo_mode
    quoted_command="$(printf %q "$command")"

    if [[ "$REMOTE_SUDO_MODE" == "nopass" ]]; then
        board_ssh "sudo bash -lc $quoted_command"
        return
    fi

    quoted_pass="$(printf %q "$BOARD_PASS")"
    board_ssh "printf '%s\n' $quoted_pass | sudo -S -p '' bash -lc $quoted_command"
}

ensure_board_access() {
    board_ssh "printf '%s\n' connected" >/dev/null || die "Could not reach ${BOARD_USER}@${BOARD_HOST} over SSH"
}

get_remote_home() {
    board_ssh 'printf "%s\n" "$HOME"'
}

wait_for_board_online() {
    local timeout="${1:-180}"
    local start

    start="$(date +%s)"
    while true; do
        if board_ssh "printf '%s\n' ready" >/dev/null 2>&1; then
            return 0
        fi
        if (( $(date +%s) - start >= timeout )); then
            return 1
        fi
        sleep 2
    done
}

wait_for_board_offline() {
    local timeout="${1:-60}"
    local start

    start="$(date +%s)"
    while true; do
        if ! board_ssh "printf '%s\n' waiting" >/dev/null 2>&1; then
            return 0
        fi
        if (( $(date +%s) - start >= timeout )); then
            return 1
        fi
        sleep 2
    done
}

request_board_reboot() {
    local quoted_pass

    detect_remote_sudo_mode

    if [[ "$REMOTE_SUDO_MODE" == "nopass" ]]; then
        board_ssh "sudo reboot" >/dev/null 2>&1 || true
        return
    fi

    quoted_pass="$(printf %q "$BOARD_PASS")"
    board_ssh "printf '%s\n' $quoted_pass | sudo -S -p '' reboot" >/dev/null 2>&1 || true
}

reboot_and_wait() {
    log_info "Requesting a board reboot"
    request_board_reboot
    sleep 2

    if wait_for_board_offline 60; then
        log_ok "Board is going down for reboot"
    else
        log_warn "Board did not clearly transition offline; waiting for SSH to return anyway"
    fi

    wait_for_board_online 180 || die "Board did not come back over SSH after reboot"
    log_ok "Board is reachable again after reboot"
}

require_host_tools() {
    local missing=()
    local tool

    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if [[ -n "$BOARD_PASS" ]] && ! command -v sshpass >/dev/null 2>&1; then
        missing+=("sshpass")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required host tools: ${missing[*]}"
    fi
}

ensure_toolchain() {
    local compiler="${TOOLCHAIN_BIN_DIR}/${CROSS_COMPILE_PREFIX}gcc"
    local archive_path="$SOURCES_DIR/toolchains/$TOOLCHAIN_ARCHIVE"

    mkdir -p "$SOURCES_DIR/toolchains"

    if [[ -x "$compiler" ]]; then
        log_ok "Reusing cross toolchain at $TOOLCHAIN_DIR"
        return
    fi

    if [[ ! -f "$archive_path" ]]; then
        log_info "Downloading SpacemiT cross toolchain archive"
        curl -fL --retry 3 --retry-delay 2 -o "$archive_path" "$TOOLCHAIN_URL"
    else
        log_ok "Reusing downloaded toolchain archive $archive_path"
    fi

    log_info "Extracting SpacemiT cross toolchain into $SOURCES_DIR/toolchains"
    tar -Jxf "$archive_path" -C "$SOURCES_DIR/toolchains"

    [[ -x "$compiler" ]] || die "Cross compiler was not found after extracting the toolchain: $compiler"
    log_ok "Cross toolchain is ready"
}

ensure_checkout() {
    local url="$1"
    local ref="$2"
    local dir="$3"

    if [[ -d "$dir/.git" ]]; then
        log_ok "Reusing existing checkout $dir"
        return
    fi

    mkdir -p "$(dirname "$dir")"

    log_info "Cloning $(basename "$dir") from $url"
    if [[ -n "$ref" ]]; then
        git clone --branch "$ref" "$url" "$dir"
    else
        git clone "$url" "$dir"
    fi

    log_ok "Source checkout is ready: $dir"
}

prepare_kernel_source_tree() {
    ensure_toolchain
    ensure_checkout "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_REF" "$KERNEL_SOURCE_DIR"
}

prepare_uboot_source_tree() {
    ensure_toolchain
    ensure_checkout "$UBOOT_SOURCE_URL" "$UBOOT_SOURCE_REF" "$UBOOT_SOURCE_DIR"
}
