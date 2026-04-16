#!/usr/bin/env bash

set -Eeuo pipefail

CAMERA_DEVICE=""
CAMERA_DEFAULT="/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0"
INSTALLED_WALLPAPER_DEFAULT="/usr/local/share/eaie-display-cycle/screen.png"
CAMERA_DURATION=60
SCREENSAVER_DURATION=30
DESKTOP_DURATION=30
CAMERA_SETTLE_SECONDS=2
CAMERA_SIZE="1280x720"
CAMERA_FORMAT="mjpeg"
SCREEN_SIZE="1024x600"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
DBUS_ADDR_DEFAULT="unix:path=${RUNTIME_DIR}/bus"
DBUS_ADDR="${DBUS_SESSION_BUS_ADDRESS:-$DBUS_ADDR_DEFAULT}"
WALLPAPER_MODE="fit"
RUN_ONCE=0
WALLPAPER=""

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'

current_pid=""

usage() {
    cat <<'EOF'
Usage: bash run-display-cycle-local.sh [options]

Run a repeating display-demo loop directly on the board:

1. Camera preview for 60 seconds
2. Fullscreen test-pattern "screensaver" for 30 seconds
3. Normal LXQt desktop with wallpaper for 30 seconds

This script assumes:

- you are running it on the board itself
- an LXQt Wayland session is already active
- ffplay and pcmanfm-qt are installed

Options:
  --wallpaper <file>             Local wallpaper path on the board.
                                 Default: /usr/local/share/eaie-display-cycle/screen.png
  --camera-device <path>         Preferred local V4L2 device or symlink.
  --camera-seconds <n>           Camera phase length. Default: 60
  --screensaver-seconds <n>      Test-pattern phase length. Default: 30
  --desktop-seconds <n>          Desktop phase length. Default: 30
  --camera-size <WxH>            Camera capture size. Default: 1280x720
  --camera-format <name>         Camera input format. Default: mjpeg
  --screen-size <WxH>            Screensaver pattern size. Default: 1024x600
  --wayland-display <name>       Wayland display name. Default: wayland-0
  --runtime-dir <path>           XDG runtime dir. Default: /run/user/$(id -u)
  --wallpaper-mode <mode>        pcmanfm-qt wallpaper mode. Default: fit
  --once                         Run one cycle only, then exit.
  --help                         Show this help text.

Examples:
  bash run-display-cycle-local.sh
  bash run-display-cycle-local.sh --wallpaper ~/screen.png
  bash run-display-cycle-local.sh --wallpaper ~/screen.png --once --camera-seconds 10 --screensaver-seconds 5 --desktop-seconds 5
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

cleanup() {
    stop_current_process
}

trap cleanup EXIT INT TERM

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wallpaper)
                [[ $# -ge 2 ]] || die "--wallpaper requires a value"
                WALLPAPER="$2"
                shift
                ;;
            --camera-device)
                [[ $# -ge 2 ]] || die "--camera-device requires a value"
                CAMERA_DEVICE="$2"
                shift
                ;;
            --camera-seconds)
                [[ $# -ge 2 ]] || die "--camera-seconds requires a value"
                CAMERA_DURATION="$2"
                shift
                ;;
            --screensaver-seconds)
                [[ $# -ge 2 ]] || die "--screensaver-seconds requires a value"
                SCREENSAVER_DURATION="$2"
                shift
                ;;
            --desktop-seconds)
                [[ $# -ge 2 ]] || die "--desktop-seconds requires a value"
                DESKTOP_DURATION="$2"
                shift
                ;;
            --camera-size)
                [[ $# -ge 2 ]] || die "--camera-size requires a value"
                CAMERA_SIZE="$2"
                shift
                ;;
            --camera-format)
                [[ $# -ge 2 ]] || die "--camera-format requires a value"
                CAMERA_FORMAT="$2"
                shift
                ;;
            --screen-size)
                [[ $# -ge 2 ]] || die "--screen-size requires a value"
                SCREEN_SIZE="$2"
                shift
                ;;
            --wayland-display)
                [[ $# -ge 2 ]] || die "--wayland-display requires a value"
                WAYLAND_DISPLAY="$2"
                shift
                ;;
            --runtime-dir)
                [[ $# -ge 2 ]] || die "--runtime-dir requires a value"
                RUNTIME_DIR="$2"
                DBUS_ADDR_DEFAULT="unix:path=${RUNTIME_DIR}/bus"
                DBUS_ADDR="${DBUS_SESSION_BUS_ADDRESS:-$DBUS_ADDR_DEFAULT}"
                shift
                ;;
            --wallpaper-mode)
                [[ $# -ge 2 ]] || die "--wallpaper-mode requires a value"
                WALLPAPER_MODE="$2"
                shift
                ;;
            --once)
                RUN_ONCE=1
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
    local tool
    for tool in ffplay pcmanfm-qt; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
    done
}

validate_inputs() {
    if [[ -z "$WALLPAPER" && -f "$INSTALLED_WALLPAPER_DEFAULT" ]]; then
        WALLPAPER="$INSTALLED_WALLPAPER_DEFAULT"
    fi

    [[ -n "$WALLPAPER" ]] || die "--wallpaper is required when no installed default wallpaper is available"
    [[ -f "$WALLPAPER" ]] || die "Wallpaper file not found: $WALLPAPER"
    [[ -S "${RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]] || die "Wayland socket not found: ${RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    [[ "$CAMERA_DURATION" =~ ^[0-9]+$ ]] || die "--camera-seconds must be an integer"
    [[ "$SCREENSAVER_DURATION" =~ ^[0-9]+$ ]] || die "--screensaver-seconds must be an integer"
    [[ "$DESKTOP_DURATION" =~ ^[0-9]+$ ]] || die "--desktop-seconds must be an integer"
}

gui_cmd() {
    env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
        "$@"
}

qt_gui_cmd() {
    env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
        QT_QPA_PLATFORM=wayland \
        "$@"
}

pick_camera_device() {
    local candidate

    if [[ -n "$CAMERA_DEVICE" && -e "$CAMERA_DEVICE" ]]; then
        printf '%s\n' "$CAMERA_DEVICE"
        return 0
    fi

    if [[ -e "$CAMERA_DEFAULT" ]]; then
        printf '%s\n' "$CAMERA_DEFAULT"
        return 0
    fi

    for candidate in /dev/v4l/by-id/*video-index0; do
        if [[ -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

set_wallpaper() {
    if qt_gui_cmd pcmanfm-qt --profile=lxqt --set-wallpaper "$WALLPAPER" --wallpaper-mode "$WALLPAPER_MODE"; then
        log_ok "Wallpaper set to $WALLPAPER"
    else
        log_warn "Failed to set wallpaper through pcmanfm-qt; continuing anyway"
    fi
}

stop_current_process() {
    local pid="${current_pid:-}"

    [[ -n "$pid" ]] || return 0

    if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    fi

    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true

    if command -v pkill >/dev/null 2>&1; then
        pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    fi

    current_pid=""
}

release_camera_device() {
    local camera_device="$1"

    if command -v fuser >/dev/null 2>&1 && fuser "$camera_device" >/dev/null 2>&1; then
        log_warn "Camera device is still busy; terminating leftover holders"
        fuser -k "$camera_device" >/dev/null 2>&1 || true
        sleep 1
    fi
}

run_timed_process() {
    local label="$1"
    local seconds="$2"
    shift 2

    log_info "Starting ${label} for ${seconds}s"
    "$@" &
    current_pid="$!"

    local elapsed=0
    while (( elapsed < seconds )); do
        if ! kill -0 "$current_pid" >/dev/null 2>&1; then
            wait "$current_pid" 2>/dev/null || true
            current_pid=""
            log_warn "${label} exited before the timer elapsed"
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done

    stop_current_process
    log_ok "Stopped ${label}"
}

run_camera_phase() {
    local camera_device

    if ! camera_device="$(pick_camera_device)"; then
        log_warn "No camera device found; skipping camera phase"
        sleep "$CAMERA_DURATION"
        return 0
    fi

    log_info "Using camera device: $camera_device"
    release_camera_device "$camera_device"
    run_timed_process "camera preview" "$CAMERA_DURATION" \
        gui_cmd ffplay -fs -hide_banner -loglevel error -fflags nobuffer -flags low_delay \
        -framerate 30 -f video4linux2 -input_format "$CAMERA_FORMAT" \
        -video_size "$CAMERA_SIZE" "$camera_device"
    sleep "$CAMERA_SETTLE_SECONDS"
}

run_screensaver_phase() {
    run_timed_process "screensaver" "$SCREENSAVER_DURATION" \
        gui_cmd ffplay -fs -hide_banner -loglevel error \
        -f lavfi -i "testsrc2=size=${SCREEN_SIZE}:rate=30"
}

run_desktop_phase() {
    log_info "Showing the desktop for ${DESKTOP_DURATION}s"
    sleep "$DESKTOP_DURATION"
    log_ok "Desktop phase completed"
}

main() {
    local cycle=1

    parse_args "$@"
    require_tools
    validate_inputs

    log_info "Display loop configuration"
    printf '  wallpaper: %s\n' "$WALLPAPER"
    printf '  camera seconds: %s\n' "$CAMERA_DURATION"
    printf '  screensaver seconds: %s\n' "$SCREENSAVER_DURATION"
    printf '  desktop seconds: %s\n' "$DESKTOP_DURATION"
    printf '  wayland display: %s\n' "$WAYLAND_DISPLAY"
    printf '  runtime dir: %s\n' "$RUNTIME_DIR"
    printf '  run once: %s\n' "$RUN_ONCE"

    set_wallpaper

    while true; do
        log_info "Cycle ${cycle} starting"
        run_camera_phase
        run_screensaver_phase
        run_desktop_phase
        log_ok "Cycle ${cycle} completed"

        if [[ "$RUN_ONCE" -eq 1 ]]; then
            break
        fi

        ((cycle += 1))
    done
}

main "$@"
