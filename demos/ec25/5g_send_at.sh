#!/usr/bin/env bash
###############################################################################
# 5g_send_at.sh
#
# Usage:
#   sudo ./5g_send_at.sh "AT+CPIN?" [optional_port]
#
# Description:
#   Sends a single AT command to the Quectel modem and prints the response.
###############################################################################
set -euo pipefail

CMD=${1:-}
PORT=${2:-/dev/ttyUSB2}
BAUD=115200

if [[ -z "$CMD" ]]; then
  echo "Usage: sudo $0 \"AT+CMD\" [port]"
  exit 1
fi

log() {
  local lvl=$1; shift
  local msg="$*"
  local ts; ts=$(date '+%H:%M:%S')
  local clr reset=$'\e[0m'
  case "$lvl" in
    INFO) clr=$'\e[38;5;33m' ;;
    OK)   clr=$'\e[38;5;46m' ;;
    ERR)  clr=$'\e[1;38;5;196m' ;;
  esac
  echo -e "${clr}[$ts][$lvl] $msg${reset}"
}

log INFO "Sending '$CMD' to $PORT..."

python3 - "$PORT" "$BAUD" "$CMD" <<'PY'
import os
import select
import sys
import termios
import time

port = sys.argv[1]
baud = int(sys.argv[2])
command = sys.argv[3]

baud_map = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
    230400: termios.B230400,
    460800: termios.B460800,
    921600: termios.B921600,
}

if baud not in baud_map:
    raise SystemExit(f"Unsupported baud rate: {baud}")

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = termios.IGNPAR
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = baud_map[baud]
    attrs[5] = baud_map[baud]
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)

    os.write(fd, (command + "\r").encode("ascii"))

    deadline = time.monotonic() + 3.0
    chunks = []
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if not readable:
            continue
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if not data:
            continue
        chunks.append(data)
        text = b"".join(chunks).decode("utf-8", errors="replace")
        if "\r\nOK\r\n" in text or "\r\nERROR\r\n" in text or "+CME ERROR:" in text:
            break

    response = b"".join(chunks).decode("utf-8", errors="replace")
    lines = [line for line in response.replace("\r", "").split("\n") if line and line != command]
    print("\n".join(lines) if lines else "<no response>")
finally:
    os.close(fd)
PY

log OK "Done."
