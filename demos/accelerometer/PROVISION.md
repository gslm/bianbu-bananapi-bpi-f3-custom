# EAIE Accelerometer Axis Demo — Board Provisioning

Single source of truth for every change the EAIE board needs in order to run
the accelerometer-axis demo. The companion script [provision.sh](provision.sh)
applies these changes idempotently.

## Canonical run, after every reflash

From the development host, with the repo checked out:

```bash
sshpass -p eaie ssh eaie@<board-ip> \
    'BOARD_PASS=eaie bash -s' \
    < demos/accelerometer/provision.sh
```

`BOARD_PASS` is consumed by the script's `run_sudo` helper so non-interactive
SSH invocations don't get blocked by sudo's password prompt. If the script is
run locally on the board (interactive shell), `BOARD_PASS` can be omitted and
sudo will prompt normally.

`provision.sh` is safe to re-run; every step is idempotent.

## Changes currently applied

### Packages (apt)

We use **PySide6** (Qt Company's official Python bindings) rather than PyQt6.
Bianbu's Qt 6.8.3 is compiled OpenGL-ES-only — the desktop-GL helper classes
(`QOpenGLFunctions_*_Core`) are not exported from `libQt6OpenGL.so`. The
upstream Debian `python3-pyqt6` binary references those classes and so fails
to load `QtOpenGLWidgets` on this distro. Bianbu ships their own PySide6
packages built against their Qt config, so PySide6 imports cleanly.

| Package | Why |
|---|---|
| `python3-pyside6.qtcore` | Core types, event loop, `QTimer`. |
| `python3-pyside6.qtgui` | `QSurfaceFormat`, `QPainter`, base GUI types. |
| `python3-pyside6.qtwidgets` | `QApplication`, `QMainWindow`, fullscreen handling. |
| `python3-pyside6.qtopengl` | Qt's GL helpers (`QOpenGLBuffer`, `QOpenGLShaderProgram`). |
| `python3-pyside6.qtopenglwidgets` | `QOpenGLWidget` for the 3D canvas. |
| `python3-opengl` | PyOpenGL — direct GL function calls inside `paintGL()`. |

### Desktop shortcut

Installs `~/Desktop/eaie-accelerometer-demo.desktop` so the demo is launchable
from the LXQt desktop with a double-click. Points at
`/home/eaie/demos/accelerometer/app_accel.py`. The script writes the
`.desktop` file via heredoc, so the install is self-contained and doesn't
depend on `deploy.sh` having run first.

If the demo is renamed or moved, update both the heredoc in `provision.sh`
and this section. When the demo is folded into the image build, the
`.desktop` file will move under `scripts/assets/` and be installed system-wide
into `/usr/share/applications/` (mirroring the existing
`eaie-display-cycle.desktop` pattern).

No other system changes are required for the v1 (50 Hz, sysfs-poll) demo.

## Future changes (not yet active)

These are documented here so we don't forget them when they become relevant:

- **udev rule for `/dev/iio:device1`** — only needed when we move from sysfs
  polling to the IIO buffer chardev (planned for the >100 Hz path). Will
  install a rule granting the `input` group `0640` access.
- **Launcher wrapper script** — exports `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`
  so the app can be started cleanly from an SSH shell without manual env work.
- **Python source layout under `/opt/`** — once the app stabilizes.

## Migration to the image build

When the demo is stable enough to be part of the product image, these changes
move into [scripts/build-rootfs-in-container.sh](../../scripts/build-rootfs-in-container.sh):

1. Append the PySide6 + PyOpenGL packages to `install_rootfs_packages()`,
   alongside the existing YOLOv8 stack.
2. Extend `validate_required_runtime()` so a missing PySide6 import aborts the
   build (per the README rule that partial rootfs builds are not allowed).
3. Add a new installer function (e.g. `install_accelerometer_demo_assets()`)
   that copies the app's source tree into the rootfs, called from `main()`
   through `run_timed_phase`.
4. Move the `.desktop` file out of the `provision.sh` heredoc into
   `scripts/assets/eaie-accelerometer-demo.desktop` and install it under
   `/usr/share/applications/` (system-wide), mirroring `eaie-display-cycle`.
5. Add the installed paths to `verify_generated_partition_images()`.

At that point this folder shrinks to source-only, and `provision.sh` either
becomes a no-op or is deleted.
