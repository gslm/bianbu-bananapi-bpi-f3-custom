# Agent Handoff Helper

This document is the handoff for the next agent taking over the
`bianbu-bananapi-bpi-f3-custom` workspace. It captures the current state,
validated hardware facts, important repo conventions, known pitfalls, and the
next intended task.

The main developer-facing reference is [README.md](README.md). Read it first,
then use this file as the current-session handoff.

## Operating Rules For The Next Agent

- Do not run build, flash, SSH deploy, or live board deployment commands unless
  the user explicitly asks you to run them.
- Prefer generating commands for the user to run manually. Long-running
  build/deploy commands have historically broken or timed out chat sessions.
- If SSH is needed, ask the user for the current board IP first. DHCP lease time
  is short and prior IPs are not reliable.
- The last known board IP used in this work was `192.168.28.101`, but do not
  assume it is still valid.
- Use `bash script.sh ...` (or `/bin/bash script.sh ...`) for repo scripts. The
  user's interactive shell is `zsh`, and a few helper scripts are not marked
  executable.
- Do not silently patch risky build, kernel, or deployment logic. Discuss the
  reasoning first when behavior changes could affect image reproducibility or
  flashing.
- Do not revert unrelated dirty files. This workspace commonly has generated
  artifacts, rootfs staging files, and side-task directories.
- Do not commit automatically. The user always reviews proposed commit
  messages and runs commits themselves.

## Project Overview

This repo builds and customizes a Bianbu 3.0 image for the SpacemiT K1 platform.
The current physical validation board is a Banana Pi BPI-F3, but the software
target is the EAIE custom-board profile:

```text
eaie-v1-riscv-spacemitk1
```

The intent is to keep the stock BPI-F3 behavior as a recovery baseline while
developing board-specific kernel, device-tree, rootfs, and application changes
under the EAIE board profile.

Important local paths:

- repo root:
  `/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom`
- main onboarding doc:
  [README.md](README.md)
- build config:
  [build.conf](build.conf)
- kernel tree:
  [sources/kernel/linux-6.6](sources/kernel/linux-6.6)
- U-Boot tree:
  [sources/u-boot/uboot-2022.10](sources/u-boot/uboot-2022.10)
- EAIE kernel DTS:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts)
- shared BPI-F3 common DTSI:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi)
- kernel defconfig:
  [sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig](sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig)
- accelerometer demo (built in the previous session):
  [demos/accelerometer/](demos/accelerometer/)
- commit scope rules:
  [COMMIT-SCOPE.md](COMMIT-SCOPE.md)

## Source Remotes And Build Defaults

[build.conf](build.conf) currently selects the custom source remotes:

```text
BOARD=eaie-v1-riscv-spacemitk1
KERNEL_REBUILD=no
UBOOT_REBUILD=no
FULL_CLEAN=no
SOURCE_ORIGIN=custom
EAIE_CUSTOM_KERNEL_SOURCE_URL=git@github.com:gslm/linux-6.6-spacemit-k1.git
EAIE_CUSTOM_KERNEL_SOURCE_REF=eaie-v1-riscv-spacemitk1
EAIE_CUSTOM_UBOOT_SOURCE_URL=git@github.com:gslm/uboot-2022.10-spacemit-k1.git
EAIE_CUSTOM_UBOOT_SOURCE_REF=eaie-v1-riscv-spacemitk1
```

Note: `build.conf` lists `BOARD_HOST=192.168.28.85` but the board has been
seen at `192.168.28.101` (DHCP-varying). Always confirm the current IP with
the user before using SSH-based deploy scripts.

Development credentials in the image are intentionally simple for lab work:

```text
BOARD_USER=eaie
BOARD_PASS=eaie
BOARD_SSH_PORT=22
```

Do not treat these as production credentials.

## Current Repo Dirty State At Handoff

At the time this handoff was generated, root repo status showed:

```text
 M demos/accelerometer/PROVISION.md
 D demos/accelerometer/app.py
 M demos/accelerometer/provision.sh
?? demos/accelerometer/app_accel.py
?? demos/accelerometer/docs/
```

What this means:

- `app.py` → `app_accel.py` rename — done in working tree, not yet committed.
- `provision.sh` and `PROVISION.md` modified — the desktop-shortcut step was
  added late in the previous session.
- `demos/accelerometer/docs/` is the new six-document learning reference set,
  not yet committed.

The user has not yet committed any of these. Generate commit commands for the
user to run when they ask. The natural single commit covering all four
changes would be something like:

```text
feat(kernel): Refine MPU6050 demo (rename, exit button, desktop shortcut, docs)
```

…or split per concern (rename / exit button / desktop shortcut / docs) if the
user prefers fine-grained history.

The kernel and U-Boot trees may have local generated artifacts (`debian/`,
build outputs). Do not delete or revert those without asking.

## Recently Committed Work (Previous Session)

These commits landed during the previous session — useful context for the
next agent:

```text
85950e2 feat(zt-secure-element): Track zero-trust workstream tasks
aaac0c7 feat(daemon-control): Add EAIE OLED status display service
6eddd74 fix(rootfs): Tolerate growpart NOCHANGE and stray lsblk whitespace
466575e feat(build-system): Harden apt flow and bake ML imaging stack
d9debfc feat(ntn): Add EC25 5G AT command demo script
a943a52 feat(kernel): Add MPU6050 3D visualization demo
f22a16b refactor(build-system): Rename CLAUDE-HELPER to AGENT-HANDOFF-HELPER
```

The MPU6050 demo commit is the bulk of what the user and previous agent
worked on. See "Accelerometer Demo App" below for what's in it.

## Current Validated Hardware Bring-Up

### Board Profile

The board currently boots with:

```text
/proc/device-tree/model = eaie-v1-riscv-spacemitk1
```

Runtime Linux DTB selection still uses the stock-compatible U-Boot path. The
EAIE DTB is staged using the `k1-x_deb1` runtime alias so stock U-Boot can keep
loading the expected DTB name.

### Display Panel

A 7" HDMI touchscreen is attached:

- Make/model: JRP JRP7006H
- Preferred mode: **1024×600 @ 60.95 Hz**
- Max negotiable: 1920×1080 @ 60 Hz
- Touch goes via USB to the board (not the dev machine)

This is the display the accelerometer demo renders on. Refresh-rate ceiling is
the panel itself (~61 Hz); no point rendering faster than that.

### Wayland Session

LXQt autologs into a `labwc` (wlroots-based) Wayland compositor. Important
env vars for any new GUI app launched from a non-graphical shell (SSH,
serial):

```text
XDG_RUNTIME_DIR=/run/user/1000
WAYLAND_DISPLAY=wayland-0
QT_QPA_PLATFORM=wayland
```

The accelerometer demo's `app_accel.py` and `smoke.py` auto-discover these
when not already set. New GUI apps should follow the same pattern.

### GL Stack (very important)

- GPU: Imagination PowerVR B-Series BXE-2-32 — **hardware-accelerated**.
- Driver: `pvr` via Mesa 24.01.
- API: **OpenGL ES only** (no desktop GL); reports OpenGL ES 3.2 in practice.
- Mesa software fallback (llvmpipe) is available if needed but not used.

### SPI TPM

The Infineon SLB9670 TPM 2.0 module was validated on `SPI3`.

Important facts:

- module compatible string: `infineon,slb9670`
- conservative SPI clock: `1000000`
- module 0R resistor was moved to `R7` so chip select is routed to native
  `SPI3_CS_3v3`, physical header pin 24
- `/dev/tpm0` and `/dev/tpmrm0` appeared after the correct kernel/DTS changes
- `sudo tpm2_getrandom 8 --hex` worked

Kernel-side TPM work included a SpacemiT K1X SPI handling adjustment in
`drivers/char/tpm/tpm_tis_spi_main.c` so the TPM TIS flow-control transaction
works on this controller.

### SSD1306 OLED

An SSD1306 OLED was tested on the same external-header I2C bus used later for
the MPU6050. It previously displayed text through a kernel framebuffer path.

Current status:

- the OLED node remains in the EAIE DTS as `oled@3c`
- the OLED node is intentionally disabled:

```dts
status = "disabled";
```

A new OLED status-display service was added to the build under
`scripts/assets/eaie-oled-status.{py,service}` — see the
`feat(daemon-control)` commit for details. It's separate from the
accelerometer demo.

### EC25 Modem

A Quectel EC25 module was tested on the top Mini PCIe slot. It enumerated as a
USB modem, not as a PCIe network device.

Validated indicators:

```text
mmcli -L
/org/freedesktop/ModemManager1/Modem/0 [Quectel] EC25
```

The modem exposed:

```text
ttyUSB0
ttyUSB1
ttyUSB2
ttyUSB3
```

ModemManager reported primary AT port `ttyUSB2`. SIM was missing during the
test, which was expected. A small AT-command helper script was committed to
`demos/ec25/`.

### MPU6050 IMU

The current active IMU bring-up uses a temporary MPU6050 accelerometer/gyro
module. This is a lab sensor only. Final hardware is expected to use
`LSM6DSO32TR`, so future commits will need to replace the DTS compatible and
kernel config accordingly.

Current lab wiring:

- bus: external-header `AP_I2C4_SDA_3V3` and `AP_I2C4_SCL_3V3`
- Linux I2C adapter: `i2c-4`
- active DT node: `/proc/device-tree/soc/i2c@d4012800`
- device address: `0x68`
- optional interrupt line: `GPIO_71_3v3`, physical header pin 11

Important pitfall:

- `i2c@d4013800` is not the active external-header I2C4 bus for this setup.
- The correct runtime node is `i2c@d4012800`.

Current DTS snippet in
`sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts`:

```dts
&i2c4 {
	pinctrl-names = "default";
	pinctrl-0 = <&pinctrl_i2c4_2>;
	status = "okay";

	oled@3c {
		compatible = "solomon,ssd1306";
		reg = <0x3c>;
		solomon,width = <128>;
		solomon,height = <64>;
		solomon,com-invdir;
		status = "disabled";
	};

	imu@68 {
		compatible = "invensense,mpu6050";
		reg = <0x68>;
		interrupt-parent = <&gpio>;
		interrupts = <71 IRQ_TYPE_EDGE_RISING>;
		status = "okay";
	};
};
```

Current kernel config:

```text
CONFIG_IIO=y
CONFIG_INV_MPU6050_IIO=m
CONFIG_INV_MPU6050_I2C=m
```

The running board after correct kernel and DTB deployment shows:

```text
Linux host1 6.6.63 #7 SMP PREEMPT
/sys/bus/i2c/devices/4-0068/driver -> .../bus/i2c/drivers/inv-mpu6050-i2c
/sys/bus/iio/devices/iio:device1
```

## Userspace GUI Stack — Bianbu Specifics

This section captures the lessons from the previous session about Bianbu's
Qt/Python GUI environment. **Read this before starting any new GUI work** —
several non-obvious gotchas.

### Use PySide6, not PyQt6

Bianbu's Qt 6.8.3 is built **OpenGL-ES-only** — the desktop-GL helper
classes (`QOpenGLFunctions_*_Core`) are not exported from `libQt6OpenGL.so`.

Consequences:

- Upstream Debian `python3-pyqt6` references those classes →
  `from PyQt6.QtOpenGLWidgets import QOpenGLWidget` fails with
  `undefined symbol _ZTI25QOpenGLFunctions_4_1_Core`. **PyQt6 is broken on
  this distro.**
- Bianbu ships their own PySide6 6.8.3 packages, built against their Qt
  config. Available as `python3-pyside6.qtcore`, `.qtgui`, `.qtwidgets`,
  `.qtopengl`, `.qtopenglwidgets`.

### Even on PySide6, do not use `PySide6.QtOpenGL`

The `python3-pyside6.qtopengl` package's `.abi3.so` references
`_ZTI25QOpenGLFunctions_4_0_Core`, also missing. Importing **anything** from
`PySide6.QtOpenGL` (e.g. `QOpenGLBuffer`, `QOpenGLShader`,
`QOpenGLShaderProgram`, `QOpenGLVertexArrayObject`) fails on this distro.

Working pattern used in the demo:

- Import `QOpenGLWidget` from `PySide6.QtOpenGLWidgets` (separate `.so`,
  loads cleanly).
- Use **PyOpenGL** (`python3-opengl`) directly for ALL GL function calls
  (shader compile/link, VBO/VAO, uniforms, draw calls).
- `PySide6.QtCore`, `PySide6.QtGui`, `PySide6.QtWidgets` work normally.

The `provision.sh` for the accelerometer demo installs the right packages
plus PyOpenGL.

### Verified working stack

```text
Qt:        6.8.3
PySide6:   6.8.3
PyOpenGL:  3.1.9
GL_VENDOR:   Imagination Technologies
GL_RENDERER: PowerVR B-Series BXE-2-32
GL_VERSION:  OpenGL ES 3.2 build 24.2@6603887
```

## MPU6050 Board-Side Validation Commands

Use these only as commands for the user to run unless the user explicitly asks
the agent to run them.

Confirm the deployed DTB contains the IMU:

```bash
cat /proc/device-tree/model && echo
find /proc/device-tree/soc/i2c@d4012800 -maxdepth 2 -print | grep -E 'imu@68|oled@3c'
tr -d '\0' < /proc/device-tree/soc/i2c@d4012800/status; echo
```

Confirm the chip responds electrically:

```bash
sudo i2cget -y 4 0x68 0x75
```

Expected MPU6050 `WHO_AM_I`:

```text
0x68
```

Do not rely on `i2cdetect -y 4` alone. On this adapter it prints:

```text
Warning: Can't use SMBus Quick Write command, will skip some addresses
```

That warning means useful addresses can be skipped. Use `i2cget` for explicit
register probing.

Confirm driver binding:

```bash
ls -l /sys/bus/i2c/devices/4-0068/driver || echo "no driver symlink"
cat /sys/bus/i2c/devices/4-0068/modalias
cat /sys/bus/i2c/devices/4-0068/uevent
```

Important pitfall:

- `readlink -f /sys/bus/i2c/devices/4-0068/driver` can be misleading if the
  symlink is absent.
- Prefer `ls -l /sys/bus/i2c/devices/4-0068/driver`.

Read raw values:

```bash
D=/sys/bus/iio/devices/iio:device1
cat "$D/in_accel_x_raw"
cat "$D/in_accel_y_raw"
cat "$D/in_accel_z_raw"
cat "$D/in_anglvel_x_raw"
cat "$D/in_anglvel_y_raw"
cat "$D/in_anglvel_z_raw"
```

If reads are returning all zeros after a period of intermittent I2C errors,
the chip may be stuck. Recover without rebooting via driver unbind/rebind:

```bash
echo 4-0068 | sudo tee /sys/bus/i2c/drivers/inv-mpu6050-i2c/unbind
echo 4-0068 | sudo tee /sys/bus/i2c/drivers/inv-mpu6050-i2c/bind
```

## MPU6050 Sampling Rate And Units

The current driver exposes `sampling_frequency` in Hz, not milliseconds.

The board reported:

```text
sampling_frequency = 50
sampling_frequency_available = 10 20 50 100 200 500
```

Interpretation:

```text
10 Hz  = 100 ms period
20 Hz  = 50 ms period
50 Hz  = 20 ms period
100 Hz = 10 ms period
200 Hz = 5 ms period
500 Hz = 2 ms period
```

Raw-to-physical conversion:

```text
accel_m_per_s2 = in_accel_*_raw * in_accel_scale
gyro_rad_per_s = in_anglvel_*_raw * in_anglvel_scale
```

The sysfs polling path used by the demo opens 6 files per sample (3 accel +
3 gyro) — comfortable up to ~100 Hz. For higher rates, switch to the IIO
buffered chardev (`/dev/iio:device1`), which also requires a udev rule
because the chardev is `root:root 0600`. This is documented as a future
upgrade path in [demos/accelerometer/PROVISION.md](demos/accelerometer/PROVISION.md).

## Accelerometer Demo App

This is the main artifact of the previous session. **A working PySide6 +
OpenGL ES 3 fullscreen 3D visualization of live MPU6050 data.**

### Location

Source: [demos/accelerometer/](demos/accelerometer/)

Files:

```text
demos/accelerometer/
├── app_accel.py            # the demo (renamed from app.py)
├── smoke.py                # minimal "is the GUI stack alive?" test
├── run.sh                  # board-side launcher (smoke wrapper)
├── deploy.sh               # host → board rsync
├── provision.sh            # apt installs + desktop shortcut
├── PROVISION.md            # board-side change log
├── axis-display.png        # original visual reference
└── docs/                   # six-document learning reference
    ├── README.md
    ├── 01-PYTHON-CONCEPTS.md
    ├── 02-PYSIDE6-CONCEPTS.md
    ├── 03-OPENGL-CONCEPTS.md
    ├── 04-APP-WALKTHROUGH.md
    └── 05-SCAFFOLDING.md
```

On the board: `~/demos/accelerometer/`. Desktop shortcut at
`~/Desktop/eaie-accelerometer-demo.desktop`.

### Features

- Fullscreen `QOpenGLWidget` on a dark-blue-grey background.
- 3D coordinate tripod with **G-scaled live arrows** on each axis (X red,
  Y green, Z blue). Arrow length tracks the current G value; sign flips
  the direction.
- Arrowhead cones at axis tips (16-segment closed cones).
- Faint cool-white reference grid in all three coordinate planes
  (every 0.5 G; spans ±2 G in each axis).
- Tick labels at 0.5 G intervals along each positive axis, color-matched.
- Bold `X` / `Y` / `Z` border letters at both ends of each axis.
- Top-left HUD: monospaced live G and ω readout.
- **Gyro arcs** — partial circles curling around each axis at the static
  1 G mark, length proportional to ω, direction by sign.
- **Top-right Exit button** for click/touch close.
- ESC and Ctrl+C also close.
- Robust to transient I2C errors (warns, keeps last good values, recovers).
- 50 Hz IIO sysfs polling on a `QTimer`; 50 Hz console print configurable
  via `PRINT_EVERY_N`.

### Architectural choices the next agent should know

- One static VBO + one VAO; static geometry (axes, arrows, grid) loaded once
  in `initializeGL`. Gyro arcs are streamed each frame to a reserved tail
  region via `glBufferSubData`.
- A single shader program. Vertex shader does optional per-axis G-scaling
  via `axis_idx` attribute (`0/1/2 = scale by u_g.x/y/z`, `-1 = static`).
- Two-pass render: opaque (axes / arrows / gyro) writes depth normally,
  then transparent (grid) with depth-write off and alpha blending.
- `QPainter` overlay drawn on the same widget after raw GL — used for the
  HUD, tick labels, axis letters, and Exit button.
- `_world_to_screen` projects 3D positions to 2D pixels for label
  placement, using the cached MVP from the most recent paint.

### Iteration loop

```text
host: edit demos/accelerometer/app_accel.py
host: bash demos/accelerometer/deploy.sh        # rsync to board
board: ~/demos/accelerometer/app_accel.py       # run (or use the desktop shortcut)
```

`provision.sh` is one-time-per-reflash:

```text
host: sshpass -p eaie ssh eaie@<ip> 'BOARD_PASS=eaie bash -s' \
        < demos/accelerometer/provision.sh
```

It installs PySide6 + PyOpenGL via apt and writes the desktop shortcut.

### Documentation

Six documents under `demos/accelerometer/docs/` aimed at someone with
limited Python and no PyQt/OpenGL background:

- README.md — entry point, learning order, glossary
- 01-PYTHON-CONCEPTS.md — Python idioms used
- 02-PYSIDE6-CONCEPTS.md — Qt6/PySide6 fundamentals
- 03-OPENGL-CONCEPTS.md — OpenGL ES rendering fundamentals
- 04-APP-WALKTHROUGH.md — function-by-function tour of `app_accel.py`
  (the longest doc; 25 numbered sections)
- 05-SCAFFOLDING.md — `smoke.py`, `provision.sh`, `deploy.sh`, `run.sh`

If you make non-trivial changes to `app_accel.py`, the user expects the
walkthrough doc to stay reasonably current. Line numbers in the doc are
loose (cited as ranges); narrative content matters more than exact
line numbers.

## Current Intended Next Task

The previous session **completed** what was originally tracked here as
"create a simple application that reads MPU6050 data and displays it on
the board's display screen." That task is now done — see "Accelerometer
Demo App" above.

The user has not yet specified the next task. Wait for direction. Options
they may want to pick from (and have hinted at):

1. **Visual polish on the demo**:
   - Arrowhead at the end of each gyro arc (direction indicator).
   - Saturation indication when an axis hits ±2 G or ω hits ±200 °/s.
   - Pause/freeze key for inspecting a snapshot.
   - Sensor-bias auto-zero on launch (gyro drift is non-trivial at rest).

2. **Performance / data path upgrade**:
   - Move the IMU read path from sysfs polling to the IIO buffered chardev,
     to reliably push past 50 Hz. Requires a udev rule (already documented
     in [PROVISION.md](demos/accelerometer/PROVISION.md) as a future change).

3. **Sensor fusion / orientation**:
   - Add a Madgwick or complementary filter to derive a stable orientation
     quaternion from accel + gyro. Display as a rotating board model or
     as a tilt indicator.
   - Useful for actually visualising "how the board is oriented" rather
     than just "which way gravity is pulling."

4. **Production hardware swap**:
   - Final board uses `LSM6DSO32TR`, not MPU6050. The DTS, kernel config,
     and possibly the IIO channel names will change.

5. **Image-build integration**:
   - Migrate the demo's prerequisites and source tree into
     `scripts/build-rootfs-in-container.sh`, mirroring the existing
     YOLOv8 / OLED-status patterns. Move the `.desktop` file out of the
     `provision.sh` heredoc and into `scripts/assets/`. After this, the
     demo ships with the image rather than being deployed manually.

6. **Longer-term ML pipeline**:
   - Buffered IMU capture with timestamps for training data.
   - Train a model off-board (event detection: falls, taps, shocks).
   - Run inference on the SpacemiT K1 NPU using the same toolchain that
     powers the YOLOv8 demo (`python3-spacemit-ort`).

Pick from the user's request, not from this list — these are sketches.

## Manual Build And Deploy Command References

These commands are for the user to run manually. Do not run them automatically.

Rebuild kernel package only, reduced load:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom

MAKE_JOBS=2 \
KERNEL_REBUILD=yes \
UBOOT_MODE=default \
/bin/bash scripts/build-source-artifacts.sh --uboot-mode default
```

Deploy only DTB over SSH:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom

/bin/bash scripts/deploy-live-kernel-dtb.sh \
  BOARD_HOST=<current-board-ip>
```

Deploy kernel package over SSH:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom

/bin/bash scripts/deploy-live-kernel.sh \
  BOARD_HOST=<current-board-ip> \
  KERNEL_REBUILD=no
```

Full image build using current defaults:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom

/bin/bash scripts/build-bianbu.sh
```

Full clean rebuild:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom

/bin/bash scripts/build-bianbu.sh \
  FULL_CLEAN=yes \
  KERNEL_REBUILD=yes \
  UBOOT_REBUILD=yes
```

The build writes full logs under:

```text
.bianbu-build/logs/
.bianbu-build/logs/latest.log
```

Inspect logs before flashing.

## Demo Iteration Commands

For the accelerometer demo specifically:

Provision the board (one-time-per-reflash):

```bash
sshpass -p eaie ssh eaie@<board-ip> \
  'BOARD_PASS=eaie bash -s' \
  < demos/accelerometer/provision.sh
```

Sync demo files from host to board (per edit):

```bash
bash demos/accelerometer/deploy.sh
```

Override targets via env: `BOARD_HOST`, `BOARD_USER`, `BOARD_PASS`,
`REMOTE_DIR`.

Run the demo (board-side):

```bash
~/demos/accelerometer/app_accel.py
# OR double-click "EAIE Accelerometer Demo" on the LXQt desktop
```

Run the smoke test (when troubleshooting GUI stack issues):

```bash
~/demos/accelerometer/smoke.py
```

## Flashing Notes

The repo has a host-side fastboot flasher:

```text
scripts/eaie_flash.sh
```

The project uses a newer locally installed fastboot tool, commonly:

```text
/home/guilhermes/platform-tools/fastboot
```

Do not assume system `fastboot` is correct. If generating flash commands, use
the repo's documented/current fastboot path or ask the user.

The user previously observed host instability during large fastboot transfers.
Low-impact flashing was added, but it did not fully prevent system crashes on
this dev machine. Be cautious before suggesting repeated full flashes.

## Known Pitfalls

### Hardware

- DTS-only deployment is not enough when a new kernel driver/config is needed.
  This happened with MPU6050: DTB was active, I2C device existed, but the driver
  could not bind until the kernel package with `CONFIG_INV_MPU6050_I2C=m` was
  deployed.
- The active external-header I2C4 node is `i2c@d4012800`, not `i2c@d4013800`.
- Board IP changes often. Ask for the current IP before SSH.
- `i2cdetect` can skip addresses on this controller. Use `i2cget` for explicit
  register probing.

### Sensors / I2C

- `sampling_frequency` under IIO is in Hz, not milliseconds.
- Flaky I2C wiring causes intermittent `OSError(EINVAL)` on sysfs reads. The
  demo's `_on_sample` catches these, keeps last-good values, and warns
  sparsely. Worth keeping the same pattern in any future IMU app.
- After persistent I2C glitches the MPU6050 can enter a stuck state where the
  driver keeps returning zeros. Recovery without reboot:
  `echo 4-0068 | sudo tee /sys/bus/i2c/drivers/inv-mpu6050-i2c/{unbind,bind}`.

### GUI / Qt stack (Bianbu-specific)

- **Do not use PyQt6.** Bianbu's Qt is ES-only; PyQt6's `QtOpenGLWidgets`
  fails to import.
- **Do not use `PySide6.QtOpenGL`.** Same root cause; the whole module
  fails to load. Use PyOpenGL for GL-helper functionality.
- `QOpenGLWidget` from `PySide6.QtOpenGLWidgets` is fine and is the
  canonical canvas widget.
- `QPainter` on a `QOpenGLWidget` works for 2D overlays — call it AFTER
  raw GL drawing inside `paintGL`, end the painter before `paintGL`
  returns.
- For `glUniformMatrix4fv` from a NumPy matrix, pass `transpose=GL_TRUE`
  because NumPy is row-major and GL is column-major.
- ES guarantees only line width 1.0; query
  `GL_ALIASED_LINE_WIDTH_RANGE` if you need confidence. PowerVR here
  supports up to 16.0.
- Python's default SIGINT handler can't fire inside Qt's C++ event loop.
  `signal.signal(signal.SIGINT, signal.SIG_DFL)` early in `main` lets
  Ctrl+C kill the process cleanly.
- A Qt app launched from a non-graphical shell (SSH, serial) needs
  `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY=wayland-0`, and
  `QT_QPA_PLATFORM=wayland` exported. The accelerometer demo
  auto-discovers these at startup.

### Build / deploy

- The rootfs/build folders may contain root-owned files and permission-denied
  paths. Do not run broad `find`/`git status` against `rootfs/` unless needed.
- Full `bindeb-pkg` kernel packaging is slow because it builds multiple Debian
  packages including headers, tools, libc headers, and debug packages.
- A future TODO exists to split full Debian kernel packaging from a lightweight
  kernel/DTB/module iteration flow.
- Partial rootfs builds are now disabled by default (`ALLOW_PARTIAL_ROOTFS=0`).
  Failures abort the image build.

## Commit Guidance

Follow [COMMIT-SCOPE.md](COMMIT-SCOPE.md).

Listed types:

```text
feat
fix
refactor
```

Recent history also uses `docs(scope)` despite it not being in
`COMMIT-SCOPE.md`. The user has not pushed back on this; treat it as
de-facto allowed.

Relevant scopes for current work:

```text
kernel
build-system
rootfs
ai-apps
ntn
system-config
daemon-control
zt-secure-element
zt-secure-boot
uboot
```

Subject style (from existing commits): `type(scope): Subject in title case`.
Bodies are short and explanatory; some commits omit them entirely.

Suggested mappings:

- DTS and defconfig changes: `feat(kernel): ...`
- Userspace IMU demo work: `feat(kernel): ...` (precedent — the existing
  `feat(kernel): Add MPU6050 3D visualization demo` covers the demo's GUI
  app, since the demo exercises the kernel-side IIO/I2C MPU6050 driver).
  An alternative would be a new `demos` scope, which would require a
  COMMIT-SCOPE.md addition.
- Build orchestration and project docs: `feat/refactor(build-system): ...`
- OLED status daemon: `feat(daemon-control): ...`
- 5G modem helpers: `feat(ntn): ...`

Do not commit automatically. The user always reviews proposed messages and
runs `git add` + `git commit` themselves. When generating commit commands,
use HEREDOCs for the message body and prefer specific `git add <files>`
over `git add -A`.

## Auto-Memory Note

The previous agent maintained an auto-memory store at:

```text
/home/guilhermes/.claude/projects/-media-guilhermes-ssd-EAIE-bianbu-bananapi-bpi-f3-custom/memory/
```

Entries:

- `MEMORY.md` — index
- `project_board_hw.md` — board hardware facts (IIO node, display panel,
  GL stack, the PySide6-not-PyQt6 lesson, sudo pattern, etc.)
- `project_ai_demo_track.md` — YOLOv8 demo state

These are loaded automatically into the agent's context. They were updated
during the previous session with the GUI-stack lessons, IMU sysfs paths, and
display panel info. If you (next agent) operate without this memory system,
the relevant facts are also captured in this handoff.

## Immediate Next Agent Checklist

1. Read [README.md](README.md).
2. Read this handoff file fully — especially the "Userspace GUI Stack" and
   "Accelerometer Demo App" sections.
3. Skim [demos/accelerometer/docs/README.md](demos/accelerometer/docs/README.md)
   so you know what the user expects you to be familiar with re: the demo.
4. Confirm the current board IP with the user before any SSH operation.
5. Wait for the user's next-task instruction. Do not pre-emptively continue
   the demo.
6. When generating any non-trivial code change to `app_accel.py`, plan to
   keep [04-APP-WALKTHROUGH.md](demos/accelerometer/docs/04-APP-WALKTHROUGH.md)
   reasonably current.
7. Do not run build/deploy/flash commands yourself unless explicitly asked.
