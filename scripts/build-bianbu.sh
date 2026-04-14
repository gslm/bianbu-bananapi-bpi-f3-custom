#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.bianbu-build"
CONTAINER_STATE_FILE="$STATE_DIR/container-name"

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

CLEAN_BUILD=0
DOCKER_RUNNER=("docker")

usage() {
    cat <<'EOF'
Usage: scripts/build-bianbu.sh [--clean] [--help]

Builds a pinned Bianbu 3.0 LXQt image for Banana Pi BPI-F3 using the current
workspace as the Docker bind mount. The script:

1. Installs/verifies host prerequisites.
2. Downloads pinned upstream inputs into this workspace.
3. Creates or reuses a privileged Docker build container with a random name.
4. Builds the rootfs inside the container.
5. Generates both:
   - bianbu-custom.sdcard
   - bianbu-custom.zip

If qemu leaves the desktop stack partially installed in the container, the
script now packages a provisional image that repairs itself natively on the
board during the first boot and then reboots once.

Options:
  --clean    Remove prior build containers, downloads, rootfs staging, images,
             and script state before starting a fresh build.
  --help     Show this help text.
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

    ensure_apt_packages ca-certificates curl docker.io qemu-user-static

    if ! command -v sha256sum >/dev/null 2>&1; then
        die "sha256sum is required but was not found on the host."
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemctl is required on the host to register qemu-user-static."
    fi

    if ! command -v dpkg >/dev/null 2>&1; then
        die "dpkg is required on the host."
    fi

    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    ensure_docker_access
    log_ok "Host prerequisites look usable"
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
        -w /mnt \
        "$container_name" \
        bash /mnt/scripts/build-rootfs-in-container.sh

    log_ok "Container build completed"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean)
                CLEAN_BUILD=1
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

main() {
    mkdir -p "$STATE_DIR"
    parse_args "$@"

    if [[ "$CLEAN_BUILD" -eq 1 ]]; then
        install_host_prereqs
        clean_workspace
    fi

    install_host_prereqs
    download_inputs
    install_qemu_support
    ensure_builder_image

    local container_name
    container_name="$(ensure_container)"

    run_container_build "$container_name"

    log_ok "Artifacts are ready:"
    printf '  %s\n' "$ROOT_DIR/bianbu-custom.sdcard"
    printf '  %s\n' "$ROOT_DIR/bianbu-custom.zip"
}

main "$@"
