# CLAUDE Helper Handoff

This document is a handoff for another developer taking over the
`bianbu-bananapi-bpi-f3-custom` workspace. It captures the current state,
validated hardware facts, important repo conventions, known pitfalls, and the
next intended task.

The main developer-facing reference is [README.md](README.md). Read it first,
then use this file as the current-session handoff.

## Operating Rules For The Next Agent

- Do not run build, flash, SSH deploy, or live board deployment commands unless
  the user explicitly asks you to run them.
- Prefer generating commands for the user to run manually. The user requested
  this because long-running build/deploy commands can break the Codex chat
  session.
- If SSH is needed, ask the user for the current board IP first. DHCP lease time
  is short and prior IPs are not reliable.
- The last known board IP used in this work was `192.168.28.101`, but do not
  assume it is still valid.
- Use `/bin/bash script.sh ...` for repo scripts unless the script is known to
  be executable. The user's interactive shell is `zsh`, and some scripts are
  not executable.
- Do not silently patch risky build, kernel, or deployment logic. Discuss the
  reasoning first when behavior changes could affect image reproducibility or
  flashing.
- Do not revert unrelated dirty files. This workspace commonly has generated
  artifacts, rootfs staging files, and side-task directories.

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
 M scripts/assets/expand-rootfs.sh
 M scripts/build-bianbu.sh
 M scripts/build-rootfs-in-container.sh
?? check.log
?? demos/
?? scripts/assets/eaie-oled-status.py
?? scripts/assets/eaie-oled-status.service
?? scripts/zero-trust/
```

The kernel tree status was clean when checked from the orchestrator repo:

```text
git -C sources/kernel/linux-6.6 status --short
```

The U-Boot tree had generated packaging/build outputs:

```text
 M debian/control
?? debian/debhelper-build-stamp
?? debian/files
?? debian/u-boot-spacemit.substvars
?? debian/u-boot-spacemit/
```

Do not delete or revert these without asking the user. Some may be generated
artifacts from prior package builds.

## Current Validated Hardware Bring-Up

### Board Profile

The board currently boots with:

```text
/proc/device-tree/model = eaie-v1-riscv-spacemitk1
```

Runtime Linux DTB selection still uses the stock-compatible U-Boot path. The
EAIE DTB is staged using the `k1-x_deb1` runtime alias so stock U-Boot can keep
loading the expected DTB name.

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

Do not assume the OLED is the target display for the next application. The next
user request says "display screen" and likely means the HDMI/LXQt display, but
clarify before implementing UI code if needed.

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
test, which was expected.

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
CONFIG_INV_MPU6050_I2C=m
```

The running board after correct kernel and DTB deployment showed:

```text
Linux host1 6.6.63 #7 SMP PREEMPT Fri Apr 24 16:06:55 -03 2026 riscv64
CONFIG_INV_MPU6050_IIO=m
CONFIG_INV_MPU6050_I2C=m
/lib/modules/6.6.63/kernel/drivers/iio/imu/inv_mpu6050/inv-mpu6050.ko
/lib/modules/6.6.63/kernel/drivers/iio/imu/inv_mpu6050/inv-mpu6050-i2c.ko
/sys/bus/i2c/devices/4-0068/driver -> .../bus/i2c/drivers/inv-mpu6050-i2c
/sys/bus/iio/devices/iio:device1
```

Validated raw readings after moving the module:

```text
in_accel_x_raw = 754
in_accel_y_raw = 6
in_accel_z_raw = 17844
in_anglvel_x_raw = -35
in_anglvel_y_raw = 2
in_anglvel_z_raw changed between -1, 63, -10, 18
```

This confirms kernel-level MPU6050 bring-up is successful.

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

Confirm IIO channels:

```bash
for d in /sys/bus/iio/devices/iio:device*; do
  echo "== $d =="
  cat "$d/name"
  ls "$d" | grep -E 'in_accel|in_anglvel|sampling_frequency|scale'
done
```

Expected MPU6050 device:

```text
== /sys/bus/iio/devices/iio:device1 ==
mpu6050
in_accel_x_raw
in_accel_y_raw
in_accel_z_raw
in_anglvel_x_raw
in_anglvel_y_raw
in_anglvel_z_raw
sampling_frequency
```

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

Gyroscope readings are available. The driver exposes:

```text
in_anglvel_x_raw
in_anglvel_y_raw
in_anglvel_z_raw
in_anglvel_scale
```

Accelerometer readings are available. The driver exposes:

```text
in_accel_x_raw
in_accel_y_raw
in_accel_z_raw
in_accel_scale
```

Raw-to-physical conversion:

```text
accel_m_per_s2 = in_accel_*_raw * in_accel_scale
gyro_rad_per_s = in_anglvel_*_raw * in_anglvel_scale
```

For a simple display application, sysfs polling at 5 to 10 FPS is sufficient.
For future machine-learning data collection, use the IIO buffered interface with
timestamps instead of repeated sysfs file reads.

## Current Intended Next Task

The next main task is to create a simple application that reads MPU6050 data and
displays it on the board's display screen.

The user's longer-term intent is:

- collect IMU data
- train a neural network
- detect events such as board movement, falling, touches, or shocks
- eventually run the trained AI model on the board

Do not jump directly to ML. Start small.

Recommended next-step discussion:

- Confirm whether "display screen" means the HDMI/LXQt display or the old
  SSD1306 OLED. The OLED node is currently disabled, so HDMI/LXQt is the safer
  assumption, but ask if unclear.
- Decide whether the first prototype should be a terminal dashboard, an OpenCV
  window, a Qt/LXQt window, or a direct framebuffer view.
- For fastest validation, prefer a userspace app that reads IIO sysfs channels
  and displays raw/scaled values.
- Keep the first version simple: read accel XYZ, gyro XYZ, temperature if
  useful, sampling frequency, and maybe a simple movement magnitude.
- Later, add logging and buffered IIO capture for training data.

Reasonable first prototype options:

- Terminal dashboard using Python and ANSI refresh.
- OpenCV window, if the LXQt session and OpenCV GUI backend work on the board.
- Simple web dashboard served locally, viewed on the board browser or another
  machine.
- Native Qt application later if the UI becomes productized.

Avoid adding this prototype into the base image until it is validated. A good
first location would be a tracked `demos/imu/` directory unless the user wants
it installed as a system service.

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

- DTS-only deployment is not enough when a new kernel driver/config is needed.
  This happened with MPU6050: DTB was active, I2C device existed, but the driver
  could not bind until the kernel package with `CONFIG_INV_MPU6050_I2C=m` was
  deployed.
- `sampling_frequency` under IIO is in Hz, not milliseconds.
- `i2cdetect` can skip addresses on this controller. Use `i2cget` for explicit
  register probing.
- The active external-header I2C4 node is `i2c@d4012800`, not
  `i2c@d4013800`.
- Board IP changes often. Ask for the current IP before SSH.
- The rootfs/build folders may contain root-owned files and permission-denied
  paths. Do not run broad `find`/`git status` against `rootfs/` unless needed.
- Full `bindeb-pkg` kernel packaging is slow because it builds multiple Debian
  packages including headers, tools, libc headers, and debug packages.
- A future TODO exists to split full Debian kernel packaging from a lightweight
  kernel/DTB/module iteration flow.

## Commit Guidance

Follow [COMMIT-SCOPE.md](COMMIT-SCOPE.md).

Allowed types currently listed:

```text
feat
fix
refactor
```

Relevant scopes for the current work:

```text
kernel
build-system
rootfs
ai-apps
system-config
daemon-control
uboot
```

Suggested scopes:

- DTS and defconfig changes: `feat(kernel): ...`
- README/handoff documentation: `feat(build-system): ...` or
  `fix(build-system): ...` depending on context, because `docs` is not listed
  in `COMMIT-SCOPE.md`
- Demo IMU userspace app: `feat(ai-apps): ...` if it is framed as the first
  AI-data demo path, or `feat(system-config): ...` if it becomes a system
  service

Do not commit automatically unless the user explicitly asks. The user usually
wants commands generated first for review.

## Immediate Next Agent Checklist

1. Read [README.md](README.md).
2. Read this handoff file fully.
3. Confirm with the user whether the first MPU6050 display app should target
   HDMI/LXQt or another display path.
4. Do not run build/deploy commands yourself.
5. If implementing a prototype, start with a userspace sysfs/IIO reader.
6. Keep future ML/data-collection work separate from the initial display demo.
7. Document any new board-side validation commands and observed outputs.

