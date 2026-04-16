#!/usr/bin/env bash
# deploy.sh — ship the YOLOv8 demo files to the BPI-F3.
#
# Usage:
#   ./deploy.sh
#
# Prerequisites (dev machine):
#   sshpass   — sudo apt install sshpass
#   rsync     — sudo apt install rsync
#
# After deploy, start the demo from the board shell:
#   cd ~/demos/yolov8/python
#   DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 \
#     python3 run_yolov8_camera.py

set -euo pipefail

BOARD_HOST="192.168.28.85"
BOARD_USER="eaie"
BOARD_PASS="eaie"
BOARD_DEMO_DIR="/home/eaie/demos/yolov8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_NAME="yolov8n_192x320.q.onnx"
MODEL_URL="https://archive.spacemit.com/spacemit-ai/BRDK/Model_Zoo/CV/YOLOv8/${MODEL_NAME}"

ssh_board() {
    sshpass -p "${BOARD_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "${BOARD_USER}@${BOARD_HOST}" "$@"
}

rsync_to_board() {
    sshpass -p "${BOARD_PASS}" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no" \
        "$@"
}

echo "==> Checking board connectivity..."
if ! ping -c1 -W3 "${BOARD_HOST}" &>/dev/null; then
    echo "ERROR: Board ${BOARD_HOST} is not reachable."
    exit 1
fi
echo "    OK"

echo ""
echo "==> Creating directory structure on board..."
ssh_board "mkdir -p ${BOARD_DEMO_DIR}/python ${BOARD_DEMO_DIR}/data ${BOARD_DEMO_DIR}/model"

echo ""
echo "==> Syncing Python files..."
rsync_to_board \
    "${SCRIPT_DIR}/python/run_yolov8_camera.py" \
    "${SCRIPT_DIR}/python/utils.py" \
    "${BOARD_USER}@${BOARD_HOST}:${BOARD_DEMO_DIR}/python/"

echo ""
echo "==> Syncing label file..."
rsync_to_board \
    "${SCRIPT_DIR}/data/label.txt" \
    "${BOARD_USER}@${BOARD_HOST}:${BOARD_DEMO_DIR}/data/"

echo ""
echo "==> Checking / downloading model on board..."
ssh_board bash <<EOF
set -e
MODEL_PATH="${BOARD_DEMO_DIR}/model/${MODEL_NAME}"
if [ -f "\${MODEL_PATH}" ]; then
    echo "    Model already present: \${MODEL_PATH}"
else
    echo "    Downloading ${MODEL_NAME} ..."
    wget -q --show-progress -O "\${MODEL_PATH}" "${MODEL_URL}"
    echo "    Download complete."
fi
EOF

echo ""
echo "==> Deploy complete."
echo ""
echo "To run from the board shell:"
echo "  cd ~/demos/yolov8/python"
echo "  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 \\"
echo "    python3 run_yolov8_camera.py"
