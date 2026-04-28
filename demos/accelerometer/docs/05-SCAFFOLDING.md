# 05 — Supporting Scripts

The demo's working directory has four small support files alongside `app_accel.py`.
This document covers each: what it does, when you'd touch it, what to know.

## 1. `smoke.py` — minimal stack-alive test

A 60-line standalone PyQt program that proves the GUI stack works end-to-end:
fullscreen window, OpenGL ES context, ESC to exit. No sensors, no shaders,
nothing fancy. Use it when something's broken and you want to isolate the
problem.

```python
#!/usr/bin/env python3
"""EAIE accelerometer-axis smoke test — fullscreen ES3 window, ESC to exit."""

import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)

if "QT_QPA_PLATFORM" not in os.environ:
    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if os.path.exists(f"{os.environ['XDG_RUNTIME_DIR']}/wayland-0"):
        os.environ.setdefault("WAYLAND_DISPLAY", "wayland-0")
        os.environ["QT_QPA_PLATFORM"] = "wayland"

from PySide6.QtCore import Qt
from PySide6.QtGui import QSurfaceFormat
from PySide6.QtOpenGLWidgets import QOpenGLWidget
from PySide6.QtWidgets import QApplication
from OpenGL.GL import (
    GL_COLOR_BUFFER_BIT, GL_RENDERER, GL_VENDOR, GL_VERSION,
    glClear, glClearColor, glGetString,
)


class SmokeWidget(QOpenGLWidget):
    def initializeGL(self) -> None:
        print(f"GL_VENDOR:   {glGetString(GL_VENDOR).decode()}")
        print(f"GL_RENDERER: {glGetString(GL_RENDERER).decode()}")
        print(f"GL_VERSION:  {glGetString(GL_VERSION).decode()}")
        glClearColor(0.06, 0.07, 0.10, 1.0)

    def paintGL(self) -> None:
        glClear(GL_COLOR_BUFFER_BIT)

    def keyPressEvent(self, event) -> None:
        if event.key() == Qt.Key.Key_Escape:
            self.close()


def main() -> int:
    fmt = QSurfaceFormat()
    fmt.setRenderableType(QSurfaceFormat.RenderableType.OpenGLES)
    fmt.setVersion(3, 0)
    QSurfaceFormat.setDefaultFormat(fmt)

    app = QApplication(sys.argv)
    w = SmokeWidget()
    w.setWindowTitle("EAIE accelerometer axis — smoke test")
    w.showFullScreen()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
```

### What it tests

- PySide6 imports cleanly (Qt + QtOpenGLWidgets module load).
- A `QSurfaceFormat`-configured ES 3.0 context can be created on this
  hardware.
- The Wayland environment env-var auto-discovery works.
- The window appears fullscreen on the panel.
- `glClearColor` paints something visible.
- The console prints `GL_VENDOR`/`GL_RENDERER`/`GL_VERSION` — useful for
  confirming you're on hardware acceleration vs. software rendering.

### When to run it

- After a fresh reflash: confirms `provision.sh` worked.
- After a board environment change (kernel update, package upgrade): confirms
  the GUI stack is still intact.
- When `app_accel.py` mysteriously fails to start: rules out the GUI plumbing as
  the cause.

If `smoke.py` works but `app_accel.py` doesn't, the bug is in the demo's logic, not
the environment.

### Comparison to `app_accel.py`

`app_accel.py` is the same skeleton extended with:

- A vertex+fragment shader pair
- Full geometry (axes, arrows, grid, gyro arcs)
- The `ImuReader` class
- A QTimer driving sensor reads
- QPainter overlays for the HUD and labels

If you understand `smoke.py`, the rest of `app_accel.py` is "more of the same with
real content."

## 2. `provision.sh` — board prerequisite installer

```bash
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
```

### What it does

Two things, in order:

1. **Installs the Python packages** the demo needs onto the board:
   - `python3-pyside6.qtcore`, `.qtgui`, `.qtwidgets` — base PySide6 bindings.
   - `python3-pyside6.qtopengl`, `.qtopenglwidgets` — Qt's GL widgets and
     helper module.
   - `python3-opengl` — PyOpenGL.

   Then runs a quick import check to fail loudly if any of those didn't
   install correctly.

2. **Writes a desktop shortcut** to `~/Desktop/eaie-accelerometer-demo.desktop`
   so the demo is launchable from the LXQt desktop with a double-click. The
   `.desktop` content is embedded as a heredoc inside `provision.sh` itself —
   no external source file dependency, so the install runs even if `deploy.sh`
   hasn't yet copied the demo folder to the board.

### Idempotency

Re-running the script is safe. `apt-get install` of already-installed
packages is a no-op. After every board reflash, run the script once.

### `set -euo pipefail`

The defensive bash flag set:

- `-e` — exit on any command's non-zero return.
- `-u` — error on unset variables.
- `-o pipefail` — return the first non-zero status from a pipeline.

Standard bash hygiene; failures stop the script instead of silently
proceeding.

### `run_sudo`

```bash
run_sudo() {
    if [[ -n "${BOARD_PASS:-}" ]]; then
        echo "$BOARD_PASS" | sudo -S "$@"
    else
        sudo "$@"
    fi
}
```

Accommodates two invocation styles:

- **Local on the board**: no `BOARD_PASS` env var → call `sudo "$@"` and
  let it prompt the user normally.
- **Via SSH from the dev host**: pass `BOARD_PASS=eaie` and the function
  pipes it to `sudo -S` (read password from stdin) — works even without a
  TTY (which SSH-piped invocations don't have).

Used like `run_sudo apt-get update`.

### Canonical invocation

From the dev host:

```bash
sshpass -p eaie ssh eaie@<board-ip> 'BOARD_PASS=eaie bash -s' < demos/accelerometer/provision.sh
```

That command pipes the script's contents to a non-interactive bash on the
board, with `BOARD_PASS` set so `run_sudo` works without a TTY.

### What goes in here vs. the image build

`provision.sh` is for **demo-stage prerequisites**. Once the demo is part
of the product image, these `apt-get install` lines move to
`scripts/build-rootfs-in-container.sh`'s `install_rootfs_packages()` and the
provision step becomes obsolete. See [PROVISION.md](../PROVISION.md) for the
migration plan.

## 3. `deploy.sh` — host → board file sync

```bash
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
```

### What it does

Copies the demo's source files from your host machine to
`~/demos/accelerometer/` on the board, using `rsync` over SSH.

### Default targets

- Board IP: `192.168.28.101`
- User: `eaie`
- Password: `eaie`
- Remote directory: `demos/accelerometer` (relative to user's home)

All four are overridable via env vars at invocation time.

### `rsync` flags

- `-a` — archive mode (preserves permissions, timestamps, symlinks, etc.)
- `-v` — verbose; print each file as it transfers
- `-z` — compress on the wire (cheap CPU win on the LAN)
- `--delete` — remove files on the remote that no longer exist on the host
  (so renaming/deleting files doesn't leave stale copies on the board)
- `--exclude='__pycache__' --exclude='*.pyc'` — don't copy Python's bytecode
  caches

### `-e "ssh -o StrictHostKeyChecking=no"`

Tells rsync to use a custom SSH command, with host-key checking disabled.
The board's SSH host keys are regenerated on first boot after every reflash,
so strict checking would always fail until you remove the old key from
`~/.ssh/known_hosts`. We just turn the check off.

### `HERE="$(cd "$(dirname "$0")" && pwd)"`

Standard bash trick to get the absolute path of the directory containing
the script itself. Lets you run `./deploy.sh` from anywhere without
worrying about working directory.

### Iteration loop

```
1. Edit demos/accelerometer/app_accel.py on the host.
2. ./deploy.sh                  ← rsync to the board
3. SSH in and run ~/demos/accelerometer/app_accel.py
```

Steps 1 and 2 take under a second once you've got the rhythm.

## 4. `run.sh` — board-side launcher

```bash
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
```

### What it does

A tiny launcher that:

1. Exports the Wayland session env vars so a plain SSH shell can launch GUI
   apps.
2. Changes directory to the demo's folder.
3. Replaces itself with `python3 smoke.py` (note: it execs `smoke.py`, not
   `app_accel.py` — historical artifact from when smoke was the primary script).

### Note: this is somewhat redundant now

`app_accel.py` and `smoke.py` both do the env auto-discovery themselves at startup
(see [04-APP-WALKTHROUGH.md §1](04-APP-WALKTHROUGH.md#1-process-level-setup-lines-417)).
So you can run them directly:

```bash
~/demos/accelerometer/app_accel.py     # works
~/demos/accelerometer/smoke.py   # works
```

`run.sh` was useful before that auto-discovery was added. It's kept as a
"this is how to launch" entry point for documentation purposes.

If you wanted, you could update it to take the script name as an argument,
or just delete it. For now it's harmless.

### `exec` vs. plain command

`exec python3 ...` *replaces* the bash process with python3, so you don't
have an extra shell hanging around. Same exit code, slightly cleaner
process tree.

### `cd "$(dirname "$0")"`

Same trick as `deploy.sh` — change to the directory containing the script
so relative paths work. Important here because we want `python3 smoke.py`
(a relative path) to find the file regardless of where the user invokes
`run.sh` from.

## 5. Reference: how the four pieces fit together

```
HOST                                       BOARD
─────                                      ─────

[ edit app_accel.py ]
        │
        ▼
[ deploy.sh ]  ──rsync──►  ~/demos/accelerometer/
                                 │
                                 ├── app_accel.py
                                 ├── smoke.py
                                 ├── provision.sh ──── apt installs ───► system packages
                                 ├── run.sh
                                 └── ...

                             ssh in
                                 │
                                 ▼
                          $ ~/demos/accelerometer/app_accel.py
                                 │
                                 ▼
                              Qt window on HDMI panel
```

Provision is the **one-time** setup after a reflash. Deploy is the **every
edit** sync. Run is **whenever you want to launch**.

## 6. PROVISION.md and axis-display.png

Two non-script files in the demo folder:

- **`PROVISION.md`** — the human-readable changelog of board-side changes
  (what `provision.sh` does and why). Update both whenever you add a new
  prerequisite.
- **`axis-display.png`** — the original reference image that inspired the
  visual design. Decorative — never touched at runtime.

## 7. When you'd touch each file

| Change | Files to edit |
|---|---|
| Add a Python package dependency | `provision.sh` + `PROVISION.md` |
| Add a system tool dependency | `provision.sh` + `PROVISION.md` |
| Tweak the desktop-shortcut entry | `provision.sh` (the `.desktop` heredoc) + `PROVISION.md` |
| Add a runtime env var | `run.sh` (and `app_accel.py`'s startup if needed) |
| Change the board IP | `deploy.sh` (or pass `BOARD_HOST=...` once) |
| Add a new app feature | `app_accel.py` |
| Diagnose "GUI doesn't start" | run `smoke.py` first |
