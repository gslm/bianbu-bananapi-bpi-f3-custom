#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/patch-dtb-model.sh <dtb-path> <new-model> [output-dtb]

Decompiles a DTB, replaces only the top-level `model` string, recompiles the
DTB, and by default updates the file in place while keeping a `.bak` backup next
to the original file.

Example:
  bash scripts/patch-dtb-model.sh bootfs/spacemit/6.6.63/k1-x_deb1.dtb "eaie-1.0 board"
  bash scripts/patch-dtb-model.sh bootfs/spacemit/6.6.63/k1-x_deb1.dtb "eaie-1.0 board" /tmp/k1-x_deb1-patched.dtb
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 1
fi

DTB_PATH="$1"
NEW_MODEL="$2"
OUTPUT_PATH="${3:-$DTB_PATH}"

[[ -f "$DTB_PATH" ]] || {
    echo "DTB not found: $DTB_PATH" >&2
    exit 1
}

command -v dtc >/dev/null 2>&1 || {
    echo "dtc is required but was not found." >&2
    exit 1
}

TMP_DTS="$(mktemp)"
TMP_DTB="$(mktemp)"

cleanup() {
    rm -f "$TMP_DTS" "$TMP_DTB"
}

trap cleanup EXIT

dtc -q -I dtb -O dts -o "$TMP_DTS" "$DTB_PATH"

python3 - "$TMP_DTS" "$NEW_MODEL" <<'PY'
import pathlib
import re
import sys

dts_path = pathlib.Path(sys.argv[1])
new_model = sys.argv[2]
text = dts_path.read_text()

updated, count = re.subn(
    r'(^\s*model\s*=\s*)".*?";',
    lambda m: f'{m.group(1)}"{new_model}";',
    text,
    count=1,
    flags=re.MULTILINE,
)

if count != 1:
    raise SystemExit("Unable to find a top-level model property to replace.")

dts_path.write_text(updated)
PY

dtc -q -I dts -O dtb -o "$TMP_DTB" "$TMP_DTS"

if [[ "$OUTPUT_PATH" == "$DTB_PATH" ]]; then
    cp -n "$DTB_PATH" "${DTB_PATH}.bak" 2>/dev/null || true
fi

install -m 0644 "$TMP_DTB" "$OUTPUT_PATH"

echo "Patched $OUTPUT_PATH"
strings -a "$OUTPUT_PATH" | grep -F "$NEW_MODEL" >/dev/null
echo "New model string: $NEW_MODEL"
