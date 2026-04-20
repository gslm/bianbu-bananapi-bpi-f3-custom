#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

LOCAL_UBOOT_ITB=""

usage() {
    cat <<'EOF'
Usage: bash scripts/deploy-uboot-itb.sh [NAME=VALUE ...]

Rebuilds u-boot.itb from the local source tree, updates pack_dir/u-boot.itb,
and then flashes only the uboot partition through scripts/eaie_flash.sh
--uboot-only.

Defaults are loaded from:
  build.conf

Useful overrides:
  SOURCE_ORIGIN=upstream|custom
  UBOOT_SOURCE_URL=<git-url>
  UBOOT_SOURCE_REF=<git-ref>
  EAIE_CUSTOM_UBOOT_SOURCE_URL=<git-url>
  EAIE_CUSTOM_UBOOT_SOURCE_REF=<git-ref>
  FASTBOOT_BIN=<path>
  MAKE_JOBS=<n>

Examples:
  bash scripts/deploy-uboot-itb.sh
  bash scripts/deploy-uboot-itb.sh FASTBOOT_BIN=/home/guilhermes/platform-tools/fastboot
EOF
}

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

build_uboot_itb() {
    prepare_uboot_source_tree

    log_info "Building U-Boot ITB from the source tree"
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

        make -j"$MAKE_JOBS" u-boot.itb
    )

    LOCAL_UBOOT_ITB="$UBOOT_SOURCE_DIR/u-boot.itb"
    [[ -f "$LOCAL_UBOOT_ITB" ]] || die "The rebuilt U-Boot ITB is missing: $LOCAL_UBOOT_ITB"

    mkdir -p "$ROOT_DIR/pack_dir"
    cp -f "$LOCAL_UBOOT_ITB" "$ROOT_DIR/pack_dir/u-boot.itb"
    log_ok "Updated pack_dir/u-boot.itb from the rebuilt source tree"
}

flash_uboot_only() {
    log_info "Starting fastboot flashing for the rebuilt U-Boot ITB"

    if [[ "$FASTBOOT_BIN" == "fastboot" ]]; then
        sudo bash "$ROOT_DIR/scripts/eaie_flash.sh" --uboot-only
        return
    fi

    sudo env FASTBOOT_BIN="$FASTBOOT_BIN" bash "$ROOT_DIR/scripts/eaie_flash.sh" --uboot-only
}

main() {
    load_build_config
    parse_args "$@"
    finalize_deploy_settings

    require_host_tools bash git curl tar make cp

    log_info "Selected source origin: $SOURCE_ORIGIN"
    log_info "U-Boot source remote: $(format_source_with_ref "$UBOOT_SOURCE_URL" "$UBOOT_SOURCE_REF")"
    log_info "FASTBOOT_BIN: $FASTBOOT_BIN"

    build_uboot_itb
    flash_uboot_only
}

main "$@"
