#!/usr/bin/env bash
# Deploy this demo folder to ~/demos/accelerometer/ on the EAIE board.
# Override defaults via env: BOARD_HOST, BOARD_USER, BOARD_PASS, REMOTE_DIR.

set -euo pipefail

BOARD_HOST="${BOARD_HOST:-192.168.28.101}"
BOARD_USER="${BOARD_USER:-eaie}"
BOARD_PASS="${BOARD_PASS:-eaie}"
REMOTE_DIR="${REMOTE_DIR:-demos/accelerometer}"

HERE="$(cd "$(dirname "$0")" && pwd)"

sshpass -p "$BOARD_PASS" rsync -avz --delete \
    --exclude='__pycache__' --exclude='*.pyc' \
    -e "ssh -o StrictHostKeyChecking=no" \
    "$HERE/" "$BOARD_USER@$BOARD_HOST:$REMOTE_DIR/"

cat <<EOF

Deployed to $BOARD_USER@$BOARD_HOST:~/$REMOTE_DIR

To run manually:
  ssh $BOARD_USER@$BOARD_HOST
  ~/$REMOTE_DIR/run.sh

Press ESC inside the app to exit.
EOF
