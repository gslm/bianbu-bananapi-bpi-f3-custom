#!/usr/bin/env bash
# Run the accelerometer-axis demo on the EAIE board.
# Exports the Wayland session env so the app finds the LXQt compositor when
# launched from a plain SSH shell, then execs the Python entry point.

set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"

cd "$(dirname "$0")"
exec python3 smoke.py "$@"
