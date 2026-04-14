#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK_DIR="$ROOT_DIR/pack_dir"
FASTBOOT_BIN="${FASTBOOT_BIN:-fastboot}"

WAIT_TIMEOUT=30
BOOTFS_ONLY=0
MANUAL_RESET_REQUIRED=0

UDEV_RULE_PATH="/etc/udev/rules.d/99-bianbu-dfu.rules"
UDEV_RULE_CONTENT='SUBSYSTEM=="usb", ATTR{idVendor}=="361c", ATTR{idProduct}=="1001", MODE="0666", GROUP="plugdev"'

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'
COLOR_MAGENTA=$'\033[1;35m'

usage() {
    cat <<'EOF'
Usage: sudo scripts/eaie_flash.sh [--bootfs-only] [--help]

Flash the generated Bianbu image package to BPI-F3 eMMC using fastboot.

The script:
1. Validates the generated pack_dir contents.
2. Installs the BPI-F3 DFU udev rule.
3. Reminds the user to hold FDL before inserting the USB-C cable.
4. Waits for fastboot DFU detection.
5. Runs the staged fastboot flashing sequence for eMMC.

Options:
  --bootfs-only     Reflash only the bootfs partition. Useful after regenerating
                    initrd and bootfs.ext4 without changing rootfs.
  --help            Show this help text.

Environment:
  FASTBOOT_BIN      Override the fastboot binary to use.
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

cd "$PACK_DIR"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bootfs-only)
                BOOTFS_ONLY=1
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

    for tool in awk sed grep; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    command -v "$FASTBOOT_BIN" >/dev/null 2>&1 || missing+=("$FASTBOOT_BIN")

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required host tools: ${missing[*]}"
    fi
}

validate_pack_dir() {
    log_info "Validating eMMC flashing inputs in $PACK_DIR"

    local required=("$PACK_DIR/bootfs.ext4")

    if [[ "$BOOTFS_ONLY" -eq 0 ]]; then
        required+=(
            "$PACK_DIR/partition_universal.json"
            "$PACK_DIR/factory/bootinfo_emmc.bin"
            "$PACK_DIR/factory/FSBL.bin"
            "$PACK_DIR/env.bin"
            "$PACK_DIR/fw_dynamic.itb"
            "$PACK_DIR/u-boot.itb"
            "$PACK_DIR/rootfs.ext4"
        )
    fi

    local file
    for file in "${required[@]}"; do
        [[ -f "$file" ]] || die "Required flashing input is missing: $file"
    done

    log_ok "Flashing inputs are present"
}

install_udev_rule() {
    log_info "Installing the BPI-F3 DFU udev rule"

    if [[ -f "$UDEV_RULE_PATH" ]] && grep -Fxq "$UDEV_RULE_CONTENT" "$UDEV_RULE_PATH"; then
        log_ok "The DFU udev rule is already installed"
    else
        printf '%s\n' "$UDEV_RULE_CONTENT" | run_as_root tee "$UDEV_RULE_PATH" >/dev/null
        log_ok "The DFU udev rule was written to $UDEV_RULE_PATH"
    fi

    run_as_root udevadm control --reload-rules
    run_as_root udevadm trigger
    log_ok "udev rules were reloaded"
}

prompt_fdl() {
    printf '\n'
    printf '%s%s%s\n' "$COLOR_MAGENTA" "Manual step required:" "$COLOR_RESET"
    printf '  1. Disconnect the board USB-C cable.\n'
    printf '  2. Hold the FDL button (SW2).\n'
    printf '  3. While holding FDL, insert the USB-C cable.\n'
    printf '  4. If desired, watch the UART in a separate terminal.\n'
    printf '\n'
    read -r -p "Press Enter after you are holding FDL and have inserted the USB-C cable..."
}

fastboot_wait_for_device() {
    local started elapsed output
    started="$(date +%s)"

    log_step "Waiting for the board to appear in fastboot DFU mode via $FASTBOOT_BIN"
    while true; do
        output="$(run_as_root "$FASTBOOT_BIN" devices 2>&1 || true)"
        if grep -Eiq '(^[^[:space:]]+[[:space:]]+fastboot([[:space:]]|$))|(DFU download)|(Android Fastboot)' <<<"$output"; then
            printf '%s\n' "$output"
            if grep -q "DFU download" <<<"$output"; then
                log_ok "fastboot detected the board in ROM DFU mode"
            elif grep -Eiq '^[^[:space:]]+[[:space:]]+fastboot([[:space:]]|$)' <<<"$output"; then
                log_ok "fastboot detected the board and reported a ready fastboot device"
            else
                log_ok "fastboot detected the board in Android Fastboot mode"
            fi
            return 0
        fi

        elapsed=$(( $(date +%s) - started ))
        if [[ "$elapsed" -ge "$WAIT_TIMEOUT" ]]; then
            printf '%s\n' "$output" >&2
            die "Timed out waiting for the board in fastboot DFU mode."
        fi

        sleep 1
    done
}

run_fastboot() {
    log_step "Running: $FASTBOOT_BIN $*"
    run_as_root "$FASTBOOT_BIN" "$@"
}

request_boot_after_flash() {
    log_step "Requesting the board to leave fastboot mode"

    if run_as_root "$FASTBOOT_BIN" reboot; then
        log_ok "The board accepted fastboot reboot"
        return 0
    fi

    log_warn "fastboot reboot is not supported by the current bootloader. Trying fastboot continue instead."

    if run_as_root "$FASTBOOT_BIN" continue; then
        log_ok "The board accepted fastboot continue"
        return 0
    fi

    MANUAL_RESET_REQUIRED=1
    log_warn "The image was flashed successfully, but the board did not accept a software reboot command."
    log_warn "Power-cycle the board or press reset manually to boot the new image."
    return 0
}

wait_after_continue() {
    sleep 1
    fastboot_wait_for_device
}

flash_emmc() {
    if [[ "$BOOTFS_ONLY" -eq 1 ]]; then
        log_info "Reflashing only the bootfs partition"
        run_fastboot flash bootfs bootfs.ext4
        request_boot_after_flash
        log_ok "bootfs-only flashing completed"
        return
    fi

    log_info "Starting the eMMC flashing sequence"

    run_fastboot stage factory/FSBL.bin
    run_fastboot continue
    wait_after_continue

    run_fastboot stage u-boot.itb
    run_fastboot continue
    wait_after_continue

    run_fastboot flash gpt partition_universal.json
    run_fastboot flash bootinfo factory/bootinfo_emmc.bin
    run_fastboot flash fsbl factory/FSBL.bin
    run_fastboot flash env env.bin
    run_fastboot flash opensbi fw_dynamic.itb
    run_fastboot flash uboot u-boot.itb
    run_fastboot flash bootfs bootfs.ext4
    run_fastboot flash rootfs rootfs.ext4

    request_boot_after_flash
    log_ok "eMMC flashing completed"
}

print_summary() {
    printf '\n'
    log_ok "Flash sequence finished"
    printf '  pack_dir: %s\n' "$PACK_DIR"
    printf '\n'
    if [[ "$BOOTFS_ONLY" -eq 1 ]]; then
        printf 'Only the bootfs partition was reflashed.\n'
    else
        printf 'The board should now boot from eMMC with the SD card removed.\n'
    fi
    if [[ "$MANUAL_RESET_REQUIRED" -eq 1 ]]; then
        printf 'A manual reset or power cycle is required because this bootloader did not accept fastboot reboot/continue.\n'
    fi
}

main() {
    parse_args "$@"
    require_tools
    validate_pack_dir
    install_udev_rule
    prompt_fdl
    fastboot_wait_for_device
    flash_emmc
    print_summary
}

main "$@"
