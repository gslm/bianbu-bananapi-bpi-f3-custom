#!/usr/bin/env bash
# Provision the EAIE board for the accelerometer-axis demo.
# Idempotent: safe to re-run after every reflash. See PROVISION.md.

set -euo pipefail

if [[ "$(uname -m)" != "riscv64" ]]; then
    echo "warning: not riscv64 (got $(uname -m)); this script targets the EAIE board." >&2
fi

run_sudo() {
    if [[ -n "${BOARD_PASS:-}" ]]; then
        echo "$BOARD_PASS" | sudo -S "$@"
    else
        sudo "$@"
    fi
}

echo "==> apt-get update"
run_sudo apt-get update

echo "==> installing PySide6 (qtcore/qtgui/qtwidgets/qtopengl/qtopenglwidgets) + PyOpenGL"
run_sudo apt-get install -y \
    python3-pyside6.qtcore \
    python3-pyside6.qtgui \
    python3-pyside6.qtwidgets \
    python3-pyside6.qtopengl \
    python3-pyside6.qtopenglwidgets \
    python3-opengl

echo "==> verifying imports"
python3 - <<'PY'
import PySide6
from PySide6 import QtCore
from PySide6.QtOpenGLWidgets import QOpenGLWidget
import OpenGL
print(f"Qt {QtCore.__version__}, PySide6 {PySide6.__version__}, PyOpenGL {OpenGL.__version__}")
PY

echo "==> done"
