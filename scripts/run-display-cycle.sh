#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOARD_HOST="192.168.28.85"
BOARD_USER="eaie"
BOARD_PASS="eaie"

LOCAL_WALLPAPER="$ROOT_DIR/screen.png"
REMOTE_DIR="/home/${BOARD_USER}/.local/share/eaie-display-cycle"
REMOTE_WALLPAPER=""

CAMERA_DEVICE=""
CAMERA_DEFAULT="/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0"
CAMERA_DURATION=60
SCREENSAVER_DURATION=30
DESKTOP_DURATION=30
CAMERA_SETTLE_SECONDS=2
CAMERA_SIZE="1280x720"
CAMERA_FORMAT="mjpeg"
SCREEN_SIZE="1024x600"
WAYLAND_DISPLAY="wayland-0"
RUNTIME_DIR="/run/user/1000"
WALLPAPER_MODE="fit"
RUN_ONCE=0

COLOR_RESET=$'\033[0m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[1;34m'

usage() {
    cat <<'EOF'
Usage: bash scripts/run-display-cycle.sh [options]

Runs a repeating display-demo loop on the Bianbu board over SSH:

1. Camera preview for 60 seconds
2. Fullscreen test-pattern "screensaver" for 30 seconds
3. Normal LXQt desktop with wallpaper for 30 seconds

The script copies screen.png from this repo to the board, sets it as the LXQt
wallpaper, and then starts the loop in the live Wayland session.

Options:
  --host <addr>                  Board IP or hostname. Default: 192.168.28.85
  --user <name>                  SSH username. Default: eaie
  --password <pass>              SSH password. Default: eaie
  --wallpaper <file>             Local wallpaper path. Default: ./screen.png
  --camera-device <path>         Preferred remote V4L2 device or symlink.
  --camera-seconds <n>           Camera phase length. Default: 60
  --screensaver-seconds <n>      Test-pattern phase length. Default: 30
  --desktop-seconds <n>          Desktop phase length. Default: 30
  --camera-size <WxH>            Camera capture size. Default: 1280x720
  --camera-format <name>         Camera input format. Default: mjpeg
  --screen-size <WxH>            Screensaver pattern size. Default: 1024x600
  --wayland-display <name>       Remote Wayland display. Default: wayland-0
  --runtime-dir <path>           Remote XDG runtime dir. Default: /run/user/1000
  --wallpaper-mode <mode>        pcmanfm-qt wallpaper mode. Default: fit
  --once                         Run one cycle only, then exit.
  --help                         Show this help text.

Examples:
  bash scripts/run-display-cycle.sh
  bash scripts/run-display-cycle.sh --once --camera-seconds 10 --screensaver-seconds 5 --desktop-seconds 5
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

ssh_base() {
    sshpass -p "$BOARD_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${BOARD_USER}@${BOARD_HOST}" "$@"
}

scp_to_board() {
    sshpass -p "$BOARD_PASS" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$1" "${BOARD_USER}@${BOARD_HOST}:$2"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                [[ $# -ge 2 ]] || die "--host requires a value"
                BOARD_HOST="$2"
                shift
                ;;
            --user)
                [[ $# -ge 2 ]] || die "--user requires a value"
                BOARD_USER="$2"
                shift
                ;;
            --password)
                [[ $# -ge 2 ]] || die "--password requires a value"
                BOARD_PASS="$2"
                shift
                ;;
            --wallpaper)
                [[ $# -ge 2 ]] || die "--wallpaper requires a value"
                LOCAL_WALLPAPER="$2"
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
    for tool in sshpass ssh scp basename; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required host tool: $tool"
    done
}

validate_inputs() {
    [[ -f "$LOCAL_WALLPAPER" ]] || die "Wallpaper file not found: $LOCAL_WALLPAPER"
    [[ "$CAMERA_DURATION" =~ ^[0-9]+$ ]] || die "--camera-seconds must be an integer"
    [[ "$SCREENSAVER_DURATION" =~ ^[0-9]+$ ]] || die "--screensaver-seconds must be an integer"
    [[ "$DESKTOP_DURATION" =~ ^[0-9]+$ ]] || die "--desktop-seconds must be an integer"
}

prepare_remote_assets() {
    REMOTE_DIR="/home/${BOARD_USER}/.local/share/eaie-display-cycle"
    REMOTE_WALLPAPER="${REMOTE_DIR}/$(basename "$LOCAL_WALLPAPER")"

    log_info "Preparing remote wallpaper directory on ${BOARD_USER}@${BOARD_HOST}"
    ssh_base "mkdir -p '$REMOTE_DIR'"

    log_info "Copying wallpaper to the board"
    scp_to_board "$LOCAL_WALLPAPER" "$REMOTE_WALLPAPER"
    log_ok "Wallpaper copied to $REMOTE_WALLPAPER"
}

run_remote_loop() {
    log_info "Starting the remote display loop"
    printf '  host: %s@%s\n' "$BOARD_USER" "$BOARD_HOST"
    printf '  wallpaper: %s\n' "$REMOTE_WALLPAPER"
    printf '  camera seconds: %s\n' "$CAMERA_DURATION"
    printf '  screensaver seconds: %s\n' "$SCREENSAVER_DURATION"
    printf '  desktop seconds: %s\n' "$DESKTOP_DURATION"
    printf '  run once: %s\n' "$RUN_ONCE"

    sshpass -p "$BOARD_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${BOARD_USER}@${BOARD_HOST}" \
        bash -s -- \
        "$REMOTE_WALLPAPER" \
        "$CAMERA_DEVICE" \
        "$CAMERA_DEFAULT" \
        "$CAMERA_DURATION" \
        "$SCREENSAVER_DURATION" \
        "$DESKTOP_DURATION" \
        "$CAMERA_SETTLE_SECONDS" \
        "$CAMERA_SIZE" \
        "$CAMERA_FORMAT" \
        "$SCREEN_SIZE" \
        "$WAYLAND_DISPLAY" \
        "$RUNTIME_DIR" \
        "$WALLPAPER_MODE" \
        "$RUN_ONCE" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

REMOTE_WALLPAPER="$1"
CAMERA_DEVICE_OVERRIDE="$2"
CAMERA_DEVICE_DEFAULT="$3"
CAMERA_DURATION="$4"
SCREENSAVER_DURATION="$5"
DESKTOP_DURATION="$6"
CAMERA_SETTLE_SECONDS="$7"
CAMERA_SIZE="$8"
CAMERA_FORMAT="$9"
SCREEN_SIZE="${10}"
WAYLAND_DISPLAY="${11}"
RUNTIME_DIR="${12}"
WALLPAPER_MODE="${13}"
RUN_ONCE="${14}"

current_pid=""

log() {
    printf '[remote] %s\n' "$*"
}

gui_cmd() {
    env XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$@"
}

qt_gui_cmd() {
    env XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" QT_QPA_PLATFORM=wayland "$@"
}

cleanup() {
    stop_current_process
}

trap cleanup EXIT INT TERM

pick_camera_device() {
    local candidate

    if [[ -n "$CAMERA_DEVICE_OVERRIDE" && -e "$CAMERA_DEVICE_OVERRIDE" ]]; then
        printf '%s\n' "$CAMERA_DEVICE_OVERRIDE"
        return 0
    fi

    if [[ -e "$CAMERA_DEVICE_DEFAULT" ]]; then
        printf '%s\n' "$CAMERA_DEVICE_DEFAULT"
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
    if qt_gui_cmd pcmanfm-qt --profile=lxqt --set-wallpaper "$REMOTE_WALLPAPER" --wallpaper-mode "$WALLPAPER_MODE"; then
        log "Wallpaper set to $REMOTE_WALLPAPER"
    else
        log "Failed to set wallpaper through pcmanfm-qt; continuing anyway"
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
        log "Camera device is still busy; terminating leftover holders"
        fuser -k "$camera_device" >/dev/null 2>&1 || true
        sleep 1
    fi
}

run_timed_process() {
    local label="$1"
    local seconds="$2"
    shift 2

    log "Starting ${label} for ${seconds}s"
    "$@" &
    current_pid="$!"

    local elapsed=0
    while (( elapsed < seconds )); do
        if ! kill -0 "$current_pid" >/dev/null 2>&1; then
            wait "$current_pid" 2>/dev/null || true
            current_pid=""
            log "${label} exited before the timer elapsed"
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done

    stop_current_process
    log "Stopped ${label}"
}

run_camera_phase() {
    local camera_device

    if ! camera_device="$(pick_camera_device)"; then
        log "No camera device found; showing the desktop instead"
        sleep "$CAMERA_DURATION"
        return 0
    fi

    log "Using camera device: $camera_device"
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
    log "Showing the desktop for ${DESKTOP_DURATION}s"
    sleep "$DESKTOP_DURATION"
}

main() {
    local cycle=1

    set_wallpaper

    while true; do
        log "Cycle ${cycle} starting"
        run_camera_phase
        run_screensaver_phase
        run_desktop_phase
        log "Cycle ${cycle} completed"

        if [[ "$RUN_ONCE" -eq 1 ]]; then
            break
        fi

        ((cycle += 1))
    done
}

main
REMOTE_SCRIPT
}

main() {
    parse_args "$@"
    require_tools
    validate_inputs
    prepare_remote_assets
    run_remote_loop
}

main "$@"
