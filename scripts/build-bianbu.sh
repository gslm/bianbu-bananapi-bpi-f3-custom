#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.bianbu-build"
CONTAINER_STATE_FILE="$STATE_DIR/container-name"
SOURCE_ARTIFACT_ENV_FILE="$STATE_DIR/source-artifacts.env"
BUILD_CONF_FILE="$ROOT_DIR/build.conf"
DEFAULT_KERNEL_SOURCE_URL="https://gitee.com/bianbu-linux/linux-6.6.git"
DEFAULT_UBOOT_SOURCE_URL="https://gitee.com/bianbu-linux/uboot-2022.10.git"

CONTAINER_IMAGE="harbor.spacemit.com/bianbu/bianbu@sha256:96ada91d222fab6ab676464e622d7f5dd49f8f4b747a13fae61f3134f1547400"
CONTAINER_NAME_PREFIX="build-bianbu-rootfs"

BASE_ROOTFS_FILE="bianbu-base-25.04.2-base-riscv64.tar.gz"
BASE_ROOTFS_URL="https://archive.spacemit.com/bianbu-base/${BASE_ROOTFS_FILE}"
BASE_ROOTFS_SHA256="dcfd1e5e6c41325b423d4dbdd87d0571ea126fe28833009d116826149e30d5df"

QEMU_DEB_FILE="qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb"
QEMU_DEB_URL="https://archive.spacemit.com/qemu/qemu-user-static_8.0.4%2Bdfsg-1ubuntu3.23.10.1_amd64.deb"
QEMU_DEB_SHA256="c139202b8707431856e72023aff64bfddb368c97621bed5c2893cfb733e60585"

RVV_FILE="rvv"
RVV_URL="https://archive.spacemit.com/qemu/rvv"
RVV_SHA256="8e3e7dec5c5f90dd19cd258516d9f8781a10028aa30775cceda0fd49bf0aaa49"

FASTBOOT_YAML_URL="https://gitee.com/bianbu/firmware-config/raw/main/fastboot.yaml"
FASTBOOT_YAML_SHA256="95642b765cff5b7c6e2439e44b1b7ea70a77fd79ced3e37a907185f383545278"

PARTITION_2M_URL="https://gitee.com/bianbu/firmware-config/raw/main/partition_2M.json"
PARTITION_2M_SHA256="a14ca12559299f6fbf750465fcc87727b38445e5c0a45516394e6326396a8feb"

PARTITION_FLASH_URL="https://gitee.com/bianbu/firmware-config/raw/main/partition_flash.json"
PARTITION_FLASH_SHA256="5f1e483082de5586dcae2b8f979b89a2f0f090cc93bd2f26b80689b654a755b4"

PARTITION_UNIVERSAL_URL="https://gitee.com/bianbu/firmware-config/raw/main/partition_universal.json"
PARTITION_UNIVERSAL_SHA256="568d9848097c72ba01ded40534022d35be7dda57ece13863194dd3a442d9568e"

GEN_IMGCFG_URL="https://gitee.com/spacemit-buildroot/scripts/raw/bl-v1.0.y/gen_imgcfg.py"
GEN_IMGCFG_SHA256="a31c987831e0b4f10e4de8d0bb48468facb0ebbe87f377e14f6e0be71dd083c2"

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'
COLOR_MAGENTA=$'\033[1;35m'

DOCKER_RUNNER=("docker")
BOARD="${BOARD:-bpi-f3}"
FULL_CLEAN="${FULL_CLEAN:-no}"
KERNEL_MODE="${KERNEL_MODE:-source}"
UBOOT_MODE="${UBOOT_MODE:-source}"
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
BOARD_PROFILE=""
BOARD_DESCRIPTION=""
BOARD_SOURCE_DTB_NAME=""
BOARD_RUNTIME_DTB_NAME=""
BOARD_BOOT_ENV_NAME=""
KERNEL_SOURCE_DEB=""
UBOOT_SOURCE_DEB=""
BUILD_START_EPOCH=0
CLEAN_BUILD=0
declare -a PHASE_NAMES=()
declare -a PHASE_SECONDS=()

usage() {
    cat <<'EOF'
Usage: scripts/build-bianbu.sh [NAME=VALUE ...] [legacy options]

Builds a pinned Bianbu 3.0 LXQt image for the selected SpacemiT K1 board
profile using the current workspace as the Docker bind mount. Defaults are
loaded from:

  build.conf

and any KEY=VALUE arguments passed after the script name override those
defaults for the current invocation.

Primary KEY=VALUE settings:
  BOARD=<name>              Board profile to build. Supported values:
                            bpi-f3
                            eaie-v1-riscv-spacemitk1
  KERNEL_REBUILD=yes|no     Rebuild the source kernel package now, or reuse
                            the latest cached one.
  UBOOT_REBUILD=yes|no      Rebuild the source U-Boot package now, or reuse
                            the latest cached one.
  FULL_CLEAN=yes|no         Remove prior build state first. In source mode,
                            this forces kernel/U-Boot rebuilds as well.
  SOURCE_ORIGIN=upstream|custom
                            Select upstream remotes or EAIE custom remotes.

Advanced KEY=VALUE overrides:
  KERNEL_MODE=source|default
  UBOOT_MODE=source|default
  KERNEL_SOURCE_URL=<git-url>
  KERNEL_SOURCE_REF=<git-ref>
  UBOOT_SOURCE_URL=<git-url>
  UBOOT_SOURCE_REF=<git-ref>
  EAIE_CUSTOM_KERNEL_SOURCE_URL=<git-url>
  EAIE_CUSTOM_KERNEL_SOURCE_REF=<git-ref>
  EAIE_CUSTOM_UBOOT_SOURCE_URL=<git-url>
  EAIE_CUSTOM_UBOOT_SOURCE_REF=<git-ref>

Outputs:
   - bianbu-custom.sdcard
   - bianbu-custom.zip

Examples:
  bash scripts/build-bianbu.sh
  bash scripts/build-bianbu.sh BOARD=bpi-f3
  bash scripts/build-bianbu.sh KERNEL_REBUILD=yes
  bash scripts/build-bianbu.sh UBOOT_REBUILD=yes
  bash scripts/build-bianbu.sh FULL_CLEAN=yes
  bash scripts/build-bianbu.sh SOURCE_ORIGIN=custom

Legacy options still supported:
  --clean
  --board <name>
  --kernel-mode source|default
  --uboot-mode source|default
  --source-origin upstream|custom
  --kernel-source-url <git-url>
  --kernel-source-ref <git-ref>
  --uboot-source-url <git-url>
  --uboot-source-ref <git-ref>
  --kernel-default
  --kernel-source
  --uboot-default
  --uboot-source
  --help
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

log_error() {
    printf '%s[ERR ]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
    log_error "$*"
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

run_timed_capture() {
    local __result_var="$1"
    local label="$2"
    local start_epoch end_epoch elapsed output
    shift 2

    start_epoch="$(now_millis)"
    output="$("$@")"
    end_epoch="$(now_millis)"
    elapsed=$((end_epoch - start_epoch))

    record_phase_duration "$label" "$elapsed"
    log_ok "Phase complete: $label ($(format_duration "$elapsed"))"
    printf -v "$__result_var" '%s' "$output"
}

print_timing_summary() {
    local total_seconds="$1"
    local i

    printf '\n'
    printf '%s[SUMMARY]%s Host build timings\n' "$COLOR_MAGENTA" "$COLOR_RESET"
    for ((i = 0; i < ${#PHASE_NAMES[@]}; i++)); do
        printf '  - %s: %s\n' "${PHASE_NAMES[$i]}" "$(format_duration "${PHASE_SECONDS[$i]}")"
    done
    printf '  - Total host build time: %s\n' "$(format_duration "$total_seconds")"
}

validate_modes() {
    case "$KERNEL_MODE" in
        source|default) ;;
        *) die "Unsupported kernel mode: $KERNEL_MODE" ;;
    esac

    case "$UBOOT_MODE" in
        source|default) ;;
        *) die "Unsupported U-Boot mode: $UBOOT_MODE" ;;
    esac
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

apply_build_setting() {
    local key="$1"
    local value="$2"

    case "$key" in
        BOARD) BOARD="$value" ;;
        FULL_CLEAN) FULL_CLEAN="$value" ;;
        KERNEL_REBUILD) KERNEL_REBUILD="$value" ;;
        UBOOT_REBUILD) UBOOT_REBUILD="$value" ;;
        KERNEL_MODE) KERNEL_MODE="$value" ;;
        UBOOT_MODE) UBOOT_MODE="$value" ;;
        SOURCE_ORIGIN) SOURCE_ORIGIN="$value" ;;
        KERNEL_SOURCE_URL) KERNEL_SOURCE_URL="$value" ;;
        KERNEL_SOURCE_REF) KERNEL_SOURCE_REF="$value" ;;
        UBOOT_SOURCE_URL) UBOOT_SOURCE_URL="$value" ;;
        UBOOT_SOURCE_REF) UBOOT_SOURCE_REF="$value" ;;
        EAIE_CUSTOM_KERNEL_SOURCE_URL) EAIE_CUSTOM_KERNEL_SOURCE_URL="$value" ;;
        EAIE_CUSTOM_KERNEL_SOURCE_REF) EAIE_CUSTOM_KERNEL_SOURCE_REF="$value" ;;
        EAIE_CUSTOM_UBOOT_SOURCE_URL) EAIE_CUSTOM_UBOOT_SOURCE_URL="$value" ;;
        EAIE_CUSTOM_UBOOT_SOURCE_REF) EAIE_CUSTOM_UBOOT_SOURCE_REF="$value" ;;
        *)
            die "Unknown build setting: $key"
            ;;
    esac
}

load_build_config() {
    if [[ ! -f "$BUILD_CONF_FILE" ]]; then
        log_warn "No build.conf was found at $BUILD_CONF_FILE; using built-in defaults"
        return
    fi

    # shellcheck disable=SC1090
    source "$BUILD_CONF_FILE"
    log_info "Loaded build defaults from $BUILD_CONF_FILE"
}

finalize_build_request() {
    FULL_CLEAN="$(normalize_yes_no "$FULL_CLEAN" "FULL_CLEAN")"
    KERNEL_REBUILD="$(normalize_yes_no "$KERNEL_REBUILD" "KERNEL_REBUILD")"
    UBOOT_REBUILD="$(normalize_yes_no "$UBOOT_REBUILD" "UBOOT_REBUILD")"
    BOARD_PROFILE="$BOARD"

    if [[ "$KERNEL_MODE" == "default" && "$KERNEL_REBUILD" == "yes" ]]; then
        log_warn "Ignoring KERNEL_REBUILD=yes because KERNEL_MODE=default"
        KERNEL_REBUILD="no"
    fi

    if [[ "$UBOOT_MODE" == "default" && "$UBOOT_REBUILD" == "yes" ]]; then
        log_warn "Ignoring UBOOT_REBUILD=yes because UBOOT_MODE=default"
        UBOOT_REBUILD="no"
    fi

    if [[ "$FULL_CLEAN" == "yes" ]]; then
        CLEAN_BUILD=1
        if [[ "$KERNEL_MODE" == "source" ]]; then
            KERNEL_REBUILD="yes"
        fi
        if [[ "$UBOOT_MODE" == "source" ]]; then
            UBOOT_REBUILD="yes"
        fi
    else
        CLEAN_BUILD=0
    fi
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
            if [[ "$KERNEL_MODE" == "source" ]]; then
                [[ -n "$KERNEL_SOURCE_URL" ]] || KERNEL_SOURCE_URL="$EAIE_CUSTOM_KERNEL_SOURCE_URL"
                [[ -n "$KERNEL_SOURCE_REF" ]] || KERNEL_SOURCE_REF="$EAIE_CUSTOM_KERNEL_SOURCE_REF"
                [[ -n "$KERNEL_SOURCE_URL" ]] || die "Custom source origin requires EAIE_CUSTOM_KERNEL_SOURCE_URL or KERNEL_SOURCE_URL"
            fi
            if [[ "$UBOOT_MODE" == "source" ]]; then
                [[ -n "$UBOOT_SOURCE_URL" ]] || UBOOT_SOURCE_URL="$EAIE_CUSTOM_UBOOT_SOURCE_URL"
                [[ -n "$UBOOT_SOURCE_REF" ]] || UBOOT_SOURCE_REF="$EAIE_CUSTOM_UBOOT_SOURCE_REF"
                [[ -n "$UBOOT_SOURCE_URL" ]] || die "Custom source origin requires EAIE_CUSTOM_UBOOT_SOURCE_URL or UBOOT_SOURCE_URL"
            fi
            ;;
        *)
            die "Unsupported source origin: $SOURCE_ORIGIN"
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

resolve_board_profile() {
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

run_sudo() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

docker_cmd() {
    "${DOCKER_RUNNER[@]}" "$@"
}

ensure_docker_access() {
    if docker info >/dev/null 2>&1; then
        DOCKER_RUNNER=("docker")
        return
    fi

    if sudo docker info >/dev/null 2>&1; then
        DOCKER_RUNNER=("sudo" "docker")
        return
    fi

    die "Docker is installed but not usable. Add your user to the docker group or allow sudo docker."
}

ensure_apt_packages() {
    local missing=()
    local package

    for package in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$package")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "Missing host packages: ${missing[*]}. Automatic installation only supports apt-based hosts."
    fi

    log_warn "Installing missing host packages: ${missing[*]}"
    run_sudo apt-get update
    run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

install_host_prereqs() {
    log_info "Checking host prerequisites"

    ensure_apt_packages ca-certificates curl qemu-user-static

    if ! command -v docker >/dev/null 2>&1; then
        ensure_apt_packages docker.io
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        die "sha256sum is required but was not found on the host."
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemctl is required on the host to register qemu-user-static."
    fi

    if ! command -v dpkg >/dev/null 2>&1; then
        die "dpkg is required on the host."
    fi

    if [[ "$KERNEL_MODE" == "source" || "$UBOOT_MODE" == "source" ]]; then
        ensure_apt_packages \
            git \
            build-essential \
            bc \
            cpio \
            file \
            rsync \
            dpkg-dev \
            fakeroot \
            debhelper \
            devscripts \
            flex \
            bison \
            libssl-dev \
            libelf-dev \
            libpython3-dev \
            libgnutls28-dev \
            libncurses5-dev \
            libncurses-dev \
            libpfm4-dev \
            libtraceevent-dev \
            asciidoc \
            device-tree-compiler \
            python-is-python3 \
            python3-pyelftools \
            python3-setuptools \
            swig \
            uuid-dev \
            u-boot-tools
    fi

    if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
        run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    ensure_docker_access
    log_ok "Host prerequisites look usable"
}

prepare_source_artifacts() {
    if [[ "$KERNEL_MODE" == "default" && "$UBOOT_MODE" == "default" ]]; then
        rm -f "$SOURCE_ARTIFACT_ENV_FILE"
        KERNEL_SOURCE_DEB=""
        UBOOT_SOURCE_DEB=""
        log_ok "Using packaged kernel and packaged U-Boot artifacts"
        return
    fi

    log_info "Resolving source-built BSP artifacts"
    ARTIFACT_ENV_FILE="$SOURCE_ARTIFACT_ENV_FILE" \
    KERNEL_MODE="$KERNEL_MODE" \
    UBOOT_MODE="$UBOOT_MODE" \
    KERNEL_REBUILD="$KERNEL_REBUILD" \
    UBOOT_REBUILD="$UBOOT_REBUILD" \
    BOARD_PROFILE="$BOARD_PROFILE" \
    KERNEL_SOURCE_URL="$KERNEL_SOURCE_URL" \
    KERNEL_SOURCE_REF="$KERNEL_SOURCE_REF" \
    UBOOT_SOURCE_URL="$UBOOT_SOURCE_URL" \
    UBOOT_SOURCE_REF="$UBOOT_SOURCE_REF" \
        bash "$ROOT_DIR/scripts/build-source-artifacts.sh"

    [[ -f "$SOURCE_ARTIFACT_ENV_FILE" ]] || die "Source artifact env file was not created: $SOURCE_ARTIFACT_ENV_FILE"
    # shellcheck disable=SC1090
    source "$SOURCE_ARTIFACT_ENV_FILE"

    if [[ "$KERNEL_MODE" == "source" && -z "$KERNEL_SOURCE_DEB" ]]; then
        die "Kernel source mode was requested, but no kernel package path was produced."
    fi

    if [[ "$UBOOT_MODE" == "source" && -z "$UBOOT_SOURCE_DEB" ]]; then
        die "U-Boot source mode was requested, but no U-Boot package path was produced."
    fi
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

fetch_pinned_file() {
    local url="$1"
    local dest="$2"
    local expected_sha="$3"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ "$(sha256_file "$dest")" == "$expected_sha" ]]; then
            log_ok "Reusing pinned file $(basename "$dest")"
            return
        fi
        log_warn "Checksum mismatch for $(basename "$dest"), re-downloading"
        rm -f "$dest"
    fi

    log_info "Downloading $(basename "$dest")"
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"

    if [[ "$(sha256_file "$dest")" != "$expected_sha" ]]; then
        rm -f "$dest"
        die "Checksum verification failed for $(basename "$dest")"
    fi

    log_ok "Pinned file downloaded: $(basename "$dest")"
}

download_inputs() {
    log_info "Fetching pinned build inputs"

    fetch_pinned_file "$BASE_ROOTFS_URL" "$ROOT_DIR/$BASE_ROOTFS_FILE" "$BASE_ROOTFS_SHA256"
    fetch_pinned_file "$QEMU_DEB_URL" "$ROOT_DIR/$QEMU_DEB_FILE" "$QEMU_DEB_SHA256"
    fetch_pinned_file "$RVV_URL" "$ROOT_DIR/$RVV_FILE" "$RVV_SHA256"
    chmod +x "$ROOT_DIR/$RVV_FILE"

    fetch_pinned_file "$FASTBOOT_YAML_URL" "$ROOT_DIR/pack_dir/fastboot.yaml" "$FASTBOOT_YAML_SHA256"
    fetch_pinned_file "$PARTITION_2M_URL" "$ROOT_DIR/pack_dir/partition_2M.json" "$PARTITION_2M_SHA256"
    fetch_pinned_file "$PARTITION_FLASH_URL" "$ROOT_DIR/pack_dir/partition_flash.json" "$PARTITION_FLASH_SHA256"
    fetch_pinned_file "$PARTITION_UNIVERSAL_URL" "$ROOT_DIR/pack_dir/partition_universal.json" "$PARTITION_UNIVERSAL_SHA256"
    fetch_pinned_file "$GEN_IMGCFG_URL" "$ROOT_DIR/pack_dir/gen_imgcfg.py" "$GEN_IMGCFG_SHA256"
    chmod +x "$ROOT_DIR/pack_dir/gen_imgcfg.py"

    log_ok "Pinned inputs are ready"
}

install_qemu_support() {
    log_info "Refreshing the host qemu-user-static package"
    run_sudo apt-get update
    run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-user-static
    run_sudo systemctl restart systemd-binfmt.service

    local rvv_output
    rvv_output="$("$ROOT_DIR/$RVV_FILE" 2>&1 || true)"

    if [[ "$rvv_output" == *"spacemit"* ]]; then
        log_ok "Using host qemu-user-static: $(qemu-riscv64-static --version | head -n 1)"
        return
    fi

    log_warn "The host qemu-user-static did not pass the SpacemiT rvv check. Falling back to the pinned package."

    if dpkg-query -W -f='${Status}' binfmt-support 2>/dev/null | grep -q "install ok installed"; then
        log_warn "Purging binfmt-support because it conflicts with the SpacemiT qemu-user-static package"
        run_sudo apt-get purge -y binfmt-support
    fi

    run_sudo dpkg -i "$ROOT_DIR/$QEMU_DEB_FILE"
    run_sudo systemctl restart systemd-binfmt.service

    rvv_output="$("$ROOT_DIR/$RVV_FILE" 2>&1 || true)"
    if [[ "$rvv_output" != *"spacemit"* ]]; then
        printf '%s\n' "$rvv_output" >&2
        die "qemu-user-static verification failed; neither the host package nor the pinned fallback produced the expected rvv output."
    fi

    log_ok "Pinned qemu-user-static fallback is registered and working"
}

ensure_builder_image() {
    log_info "Ensuring the pinned builder container image is present"
    docker_cmd pull "$CONTAINER_IMAGE" >/dev/null
    log_ok "Pinned builder image is ready"
}

record_container_name() {
    local name="$1"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$name" > "$CONTAINER_STATE_FILE"
}

find_existing_container() {
    local recorded=""

    if [[ -f "$CONTAINER_STATE_FILE" ]]; then
        recorded="$(<"$CONTAINER_STATE_FILE")"
        if [[ -n "$recorded" ]] && docker_cmd ps -a --format '{{.Names}}' | grep -Fxq "$recorded"; then
            printf '%s\n' "$recorded"
            return
        fi
    fi

    mapfile -t matches < <(docker_cmd ps -a --format '{{.Names}}' | grep "^${CONTAINER_NAME_PREFIX}" || true)

    if [[ ${#matches[@]} -eq 1 ]]; then
        record_container_name "${matches[0]}"
        printf '%s\n' "${matches[0]}"
        return
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        die "Multiple existing builder containers were found (${matches[*]}). Use --clean first."
    fi
}

ensure_container_running() {
    local name="$1"
    local status

    status="$(docker_cmd inspect -f '{{.State.Running}}' "$name")"
    if [[ "$status" == "true" ]]; then
        return
    fi

    log_info "Starting existing builder container $name" >&2
    docker_cmd start "$name" >/dev/null
}

create_container() {
    local name
    name="${CONTAINER_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)-$RANDOM"

    # This function is used in command substitution, so progress logs must go to
    # stderr and stdout must contain only the container name.
    log_info "Creating builder container $name" >&2
    docker_cmd run --privileged -itd \
        -v "$ROOT_DIR:/mnt" \
        --name "$name" \
        "$CONTAINER_IMAGE" >/dev/null

    record_container_name "$name"
    printf '%s\n' "$name"
}

ensure_container() {
    local existing

    existing="$(find_existing_container || true)"
    if [[ -n "$existing" ]]; then
        log_ok "Reusing existing builder container $existing" >&2
        ensure_container_running "$existing"
        printf '%s\n' "$existing"
        return
    fi

    create_container
}

clean_workspace() {
    log_warn "Cleaning prior build state"

    mapfile -t containers < <(docker_cmd ps -a --format '{{.Names}}' | grep "^${CONTAINER_NAME_PREFIX}" || true)
    if [[ ${#containers[@]} -gt 0 ]]; then
        log_info "Removing builder containers: ${containers[*]}"
        docker_cmd rm -f "${containers[@]}" >/dev/null 2>&1 || true
    fi

    docker_cmd image rm "$CONTAINER_IMAGE" >/dev/null 2>&1 || true

    run_sudo rm -rf \
        "$ROOT_DIR/rootfs" \
        "$ROOT_DIR/bootfs" \
        "$ROOT_DIR/pack_dir" \
        "$ROOT_DIR/bootfs.ext4" \
        "$ROOT_DIR/rootfs.ext4" \
        "$ROOT_DIR/bianbu-custom.sdcard" \
        "$ROOT_DIR/bianbu-custom.zip" \
        "$ROOT_DIR/$BASE_ROOTFS_FILE" \
        "$ROOT_DIR/$QEMU_DEB_FILE" \
        "$ROOT_DIR/$RVV_FILE" \
        "$STATE_DIR"

    run_sudo rm -rf \
        "$ROOT_DIR/sources/kernel/"*.deb \
        "$ROOT_DIR/sources/u-boot/"*.deb

    mkdir -p "$STATE_DIR"
    log_ok "Previous build state removed"
}

run_container_build() {
    local container_name="$1"

    log_info "Running the rootfs and image build inside $container_name"

    docker_cmd exec \
        -e WORKSPACE=/mnt \
        -e TARGET_ROOTFS=rootfs \
        -e TARGET_BOOTFS=bootfs \
        -e PACK_DIR=pack_dir \
        -e BASE_ROOTFS="$BASE_ROOTFS_FILE" \
        -e ROOTFS_SIZE=8192M \
        -e DEFAULT_LOCALE=en_US.UTF-8 \
        -e DEFAULT_TIMEZONE=America/Sao_Paulo \
        -e DEFAULT_USER=eaie \
        -e DEFAULT_PASSWORD=eaie \
        -e BOARD_PROFILE="$BOARD_PROFILE" \
        -e BOARD_SOURCE_DTB_NAME="$BOARD_SOURCE_DTB_NAME" \
        -e BOARD_RUNTIME_DTB_NAME="$BOARD_RUNTIME_DTB_NAME" \
        -e BOARD_BOOT_ENV_NAME="$BOARD_BOOT_ENV_NAME" \
        -e KERNEL_MODE="$KERNEL_MODE" \
        -e UBOOT_MODE="$UBOOT_MODE" \
        -e KERNEL_SOURCE_DEB="$KERNEL_SOURCE_DEB" \
        -e UBOOT_SOURCE_DEB="$UBOOT_SOURCE_DEB" \
        -w /mnt \
        "$container_name" \
        bash /mnt/scripts/build-rootfs-in-container.sh

    log_ok "Container build completed"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == *=* ]]; then
            apply_build_setting "${1%%=*}" "${1#*=}"
            shift
            continue
        fi

        case "$1" in
            --clean)
                FULL_CLEAN="yes"
                ;;
            --board)
                [[ $# -ge 2 ]] || die "--board requires a value"
                BOARD="$2"
                shift
                ;;
            --kernel-mode)
                [[ $# -ge 2 ]] || die "--kernel-mode requires a value"
                KERNEL_MODE="$2"
                shift
                ;;
            --uboot-mode)
                [[ $# -ge 2 ]] || die "--uboot-mode requires a value"
                UBOOT_MODE="$2"
                shift
                ;;
            --source-origin)
                [[ $# -ge 2 ]] || die "--source-origin requires a value"
                SOURCE_ORIGIN="$2"
                shift
                ;;
            --kernel-source-url)
                [[ $# -ge 2 ]] || die "--kernel-source-url requires a value"
                KERNEL_SOURCE_URL="$2"
                shift
                ;;
            --kernel-source-ref)
                [[ $# -ge 2 ]] || die "--kernel-source-ref requires a value"
                KERNEL_SOURCE_REF="$2"
                shift
                ;;
            --uboot-source-url)
                [[ $# -ge 2 ]] || die "--uboot-source-url requires a value"
                UBOOT_SOURCE_URL="$2"
                shift
                ;;
            --uboot-source-ref)
                [[ $# -ge 2 ]] || die "--uboot-source-ref requires a value"
                UBOOT_SOURCE_REF="$2"
                shift
                ;;
            --kernel-default)
                KERNEL_MODE="default"
                ;;
            --kernel-source)
                KERNEL_MODE="source"
                ;;
            --uboot-default)
                UBOOT_MODE="default"
                ;;
            --uboot-source)
                UBOOT_MODE="source"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1. Use KEY=VALUE overrides such as BOARD=eaie-v1-riscv-spacemitk1 or run --help."
                ;;
        esac
        shift
    done
}

main() {
    mkdir -p "$STATE_DIR"
    load_build_config
    parse_args "$@"
    finalize_build_request
    validate_modes
    resolve_board_profile
    resolve_source_origin
    BUILD_START_EPOCH="$(now_millis)"

    log_info "Selected board profile: $BOARD_PROFILE ($BOARD_DESCRIPTION)"
    log_info "Board DT source name: $BOARD_SOURCE_DTB_NAME; runtime DTB name: $BOARD_RUNTIME_DTB_NAME"
    log_info "Selected source origin: $SOURCE_ORIGIN"
    log_info "Full clean requested: $FULL_CLEAN"
    log_info "Kernel rebuild requested: $KERNEL_REBUILD"
    log_info "U-Boot rebuild requested: $UBOOT_REBUILD"
    if [[ "$KERNEL_MODE" == "source" ]]; then
        log_info "Kernel source remote: $(format_source_with_ref "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_REF")"
    else
        log_info "Kernel source mode disabled; packaged kernel artifacts will be used"
    fi
    if [[ "$UBOOT_MODE" == "source" ]]; then
        log_info "U-Boot source remote: $(format_source_with_ref "$UBOOT_SOURCE_URL" "$UBOOT_SOURCE_REF")"
    else
        log_info "U-Boot source mode disabled; packaged bootloader artifacts will be used"
    fi
    if [[ "$BOARD_SOURCE_DTB_NAME" != "$BOARD_RUNTIME_DTB_NAME" ]]; then
        log_info "This board currently relies on a runtime DTB alias so stock U-Boot can keep selecting $BOARD_RUNTIME_DTB_NAME.dtb"
    fi

    if [[ "$CLEAN_BUILD" -eq 1 ]]; then
        run_timed_phase "Host prerequisites (pre-clean)" install_host_prereqs
        run_timed_phase "Clean prior build state" clean_workspace
    fi

    run_timed_phase "Host prerequisites" install_host_prereqs
    run_timed_phase "Prepare source-built BSP artifacts" prepare_source_artifacts
    run_timed_phase "Fetch pinned build inputs" download_inputs
    run_timed_phase "Refresh host qemu-user-static" install_qemu_support
    run_timed_phase "Ensure pinned builder image" ensure_builder_image

    local container_name
    run_timed_capture container_name "Ensure builder container" ensure_container

    run_timed_phase "Container rootfs and image build" run_container_build "$container_name"

    log_ok "Artifacts are ready:"
    printf '  %s\n' "$ROOT_DIR/bianbu-custom.sdcard"
    printf '  %s\n' "$ROOT_DIR/bianbu-custom.zip"
    print_timing_summary "$(( $(now_millis) - BUILD_START_EPOCH ))"
}

main "$@"
