#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.bianbu-build}"
SOURCES_DIR="${SOURCES_DIR:-$ROOT_DIR/sources}"
ARTIFACT_ENV_FILE="${ARTIFACT_ENV_FILE:-$STATE_DIR/source-artifacts.env}"

KERNEL_MODE="${KERNEL_MODE:-source}"
UBOOT_MODE="${UBOOT_MODE:-source}"

KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-https://gitee.com/bianbu-linux/linux-6.6.git}"
KERNEL_SOURCE_REF="${KERNEL_SOURCE_REF:-}"
KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR:-$SOURCES_DIR/kernel/linux-6.6}"

UBOOT_SOURCE_URL="${UBOOT_SOURCE_URL:-https://gitee.com/bianbu-linux/uboot-2022.10.git}"
UBOOT_SOURCE_REF="${UBOOT_SOURCE_REF:-}"
UBOOT_SOURCE_DIR="${UBOOT_SOURCE_DIR:-$SOURCES_DIR/u-boot/uboot-2022.10}"

TOOLCHAIN_VERSION="${TOOLCHAIN_VERSION:-spacemit-toolchain-linux-glibc-x86_64-v1.0.0}"
TOOLCHAIN_ARCHIVE="${TOOLCHAIN_VERSION}.tar.xz"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://archive.spacemit.com/toolchain/${TOOLCHAIN_ARCHIVE}}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$SOURCES_DIR/toolchains/$TOOLCHAIN_VERSION}"
TOOLCHAIN_BIN_DIR="$TOOLCHAIN_DIR/bin"

ARCH="${ARCH:-riscv}"
CROSS_COMPILE_PREFIX="${CROSS_COMPILE_PREFIX:-riscv64-unknown-linux-gnu-}"
MAKE_JOBS="${MAKE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'

KERNEL_SOURCE_DEB=""
UBOOT_SOURCE_DEB=""

log_info() {
    printf '%s[SOURCE]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
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

usage() {
    cat <<'EOF'
Usage: scripts/build-source-artifacts.sh [--kernel-mode source|default] [--uboot-mode source|default]

Build host-side kernel and/or U-Boot source artifacts for the Bianbu image
pipeline and write the selected artifact paths to:

  .bianbu-build/source-artifacts.env

Source mode behavior:

- reuses an existing source checkout if present
- clones the source tree only when missing
- downloads and reuses the SpacemiT cross toolchain under sources/toolchains/
- builds Debian packages from source

Default mode behavior:

- skips the source build for that component
- leaves artifact env values empty for that component

Environment overrides:
  KERNEL_SOURCE_URL
  KERNEL_SOURCE_REF
  UBOOT_SOURCE_URL
  UBOOT_SOURCE_REF
  TOOLCHAIN_URL
  TOOLCHAIN_VERSION
  TOOLCHAIN_DIR
  CROSS_COMPILE_PREFIX
  MAKE_JOBS
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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

find_latest_file() {
    local dir="$1"
    local pattern="$2"

    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' \
        | sort -nr \
        | head -n 1 \
        | cut -d' ' -f2-
}

relpath_from_root() {
    local abs="$1"
    printf '%s\n' "${abs#$ROOT_DIR/}"
}

build_kernel_source_package() {
    local package_dir="$SOURCES_DIR/kernel"
    local latest_deb=""

    ensure_checkout "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_REF" "$KERNEL_SOURCE_DIR"

    log_info "Building kernel Debian package from source"
    (
        cd "$KERNEL_SOURCE_DIR"
        export PATH="$TOOLCHAIN_BIN_DIR:$PATH"
        export ARCH="$ARCH"
        export CROSS_COMPILE="$CROSS_COMPILE_PREFIX"
        export LOCALVERSION=""

        if [[ -f .config ]]; then
            make olddefconfig
        else
            make k1_defconfig
        fi

        make -j"$MAKE_JOBS" bindeb-pkg
    )

    latest_deb="$(
        find "$package_dir" -maxdepth 1 -type f -name 'linux-image-*.deb' ! -name 'linux-image-*-dbg_*.deb' \
            -printf '%T@ %p\n' \
            | sort -nr \
            | head -n 1 \
            | cut -d' ' -f2-
    )"
    [[ -n "$latest_deb" ]] || die "No linux-image Debian package was produced under $package_dir"

    KERNEL_SOURCE_DEB="$(relpath_from_root "$latest_deb")"
    log_ok "Kernel package ready: $KERNEL_SOURCE_DEB"
}

prepare_uboot_changelog() {
    local source_dir="$1"
    local version

    [[ -d "$source_dir/debian" ]] || die "The U-Boot source tree does not contain Debian packaging metadata: $source_dir/debian"

    version="1~$(git -C "$source_dir" rev-parse --short HEAD)"

    rm -f "$source_dir/debian/changelog"
    (
        cd "$source_dir"
        export DEBFULLNAME="EAIE Build"
        export DEBEMAIL="eaie@example.invalid"
        dch --create --distribution unstable --package u-boot-spacemit \
            --newversion "$version" "Local source build for EAIE Bianbu automation"
    )
}

build_uboot_source_package() {
    local package_dir="$SOURCES_DIR/u-boot"
    local latest_deb=""

    ensure_checkout "$UBOOT_SOURCE_URL" "$UBOOT_SOURCE_REF" "$UBOOT_SOURCE_DIR"

    log_info "Building U-Boot Debian package from source"
    (
        cd "$UBOOT_SOURCE_DIR"
        export PATH="$TOOLCHAIN_BIN_DIR:$PATH"
        export ARCH="$ARCH"
        export CROSS_COMPILE="$CROSS_COMPILE_PREFIX"

        if [[ -f .config ]]; then
            make olddefconfig
        else
            make k1_defconfig
        fi

        prepare_uboot_changelog "$UBOOT_SOURCE_DIR"
        dpkg-buildpackage -us -uc -b
    )

    latest_deb="$(find_latest_file "$package_dir" 'u-boot-spacemit*.deb')"
    [[ -n "$latest_deb" ]] || die "No U-Boot Debian package was produced under $package_dir"

    UBOOT_SOURCE_DEB="$(relpath_from_root "$latest_deb")"
    log_ok "U-Boot package ready: $UBOOT_SOURCE_DEB"
}

write_artifact_env_file() {
    mkdir -p "$STATE_DIR"
    cat >"$ARTIFACT_ENV_FILE" <<EOF
KERNEL_MODE='$KERNEL_MODE'
UBOOT_MODE='$UBOOT_MODE'
KERNEL_SOURCE_DEB='${KERNEL_SOURCE_DEB}'
UBOOT_SOURCE_DEB='${UBOOT_SOURCE_DEB}'
EOF

    log_ok "Wrote source artifact selections to $ARTIFACT_ENV_FILE"
}

main() {
    parse_args "$@"
    validate_modes

    mkdir -p "$SOURCES_DIR/kernel" "$SOURCES_DIR/u-boot"

    if [[ "$KERNEL_MODE" == "source" || "$UBOOT_MODE" == "source" ]]; then
        ensure_toolchain
    fi

    if [[ "$KERNEL_MODE" == "source" ]]; then
        build_kernel_source_package
    fi

    if [[ "$UBOOT_MODE" == "source" ]]; then
        build_uboot_source_package
    fi

    write_artifact_env_file
}

main "$@"
