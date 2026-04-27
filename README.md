# EAIE Bianbu BSP README

This document is the main onboarding reference for developers entering this
workspace. It consolidates the system-development direction, board-profile
model, build workflow, flashing flow, kernel bring-up notes, and practical
board FAQ items for the current Banana Pi BPI-F3 baseline and the EAIE custom
board target.

## Introduction

This repository is a Bianbu 3.0 image-build and board-bring-up workspace for
the SpacemiT K1 platform.

The current hardware validation baseline is the Banana Pi BPI-F3. That stock
board is being used as the active development target.

The project goals are:

- build Bianbu-based Debian/Ubuntu-style images with `systemd`, package
  management, and LXQt
- keep the stock BPI-F3 as a known-good recovery baseline
- introduce a separate EAIE board profile instead of mutating the stock board
  target in place
- keep the kernel and U-Boot source paths under explicit build control

The current EAIE custom board target name is:

```text
eaie-v1-riscv-spacemitk1
```

## Build Automation Snapshot

The automation for this workspace is split into:

- [scripts/build-bianbu.sh](scripts/build-bianbu.sh)
  Host-side orchestration.
- [scripts/build-source-artifacts.sh](scripts/build-source-artifacts.sh)
  Host-side kernel/U-Boot source checkout and package build helper.
- [scripts/build-rootfs-in-container.sh](scripts/build-rootfs-in-container.sh)
  Container-side rootfs and image builder.
- [scripts/eaie_flash.sh](scripts/eaie_flash.sh)
  Host-side eMMC fastboot flasher.
- [scripts/deploy-live-kernel.sh](scripts/deploy-live-kernel.sh)
  Live kernel-package deploy over SSH.
- [scripts/deploy-live-kernel-dtb.sh](scripts/deploy-live-kernel-dtb.sh)
  Live kernel-DTB-only deploy over SSH.
- [scripts/deploy-uboot-itb.sh](scripts/deploy-uboot-itb.sh)
  Rebuild U-Boot ITB and flash only the uboot partition.
- [scripts/run-display-cycle-local.sh](scripts/run-display-cycle-local.sh)
  Board-local HDMI demo loop.
- [scripts/assets/expand-rootfs.sh](scripts/assets/expand-rootfs.sh)
  First-boot rootfs grow helper.
- [scripts/assets/expand-rootfs.service](scripts/assets/expand-rootfs.service)
  Systemd unit that runs the grow helper once.
- [scripts/assets/firstboot-repair.sh](scripts/assets/firstboot-repair.sh)
  First-boot native package-repair helper.
- [scripts/assets/firstboot-repair.service](scripts/assets/firstboot-repair.service)
  Systemd unit that repairs a partial image on the board.
- [scripts/assets/eaie-display-cycle.desktop](scripts/assets/eaie-display-cycle.desktop)
  LXQt launcher for the built-in HDMI demo loop.

The automation is pinned to the current validated inputs already used in this
workspace, including:

- builder image:
  `harbor.spacemit.com/bianbu/bianbu@sha256:96ada91d222fab6ab676464e622d7f5dd49f8f4b747a13fae61f3134f1547400`
- base rootfs:
  `bianbu-base-25.04.2-base-riscv64.tar.gz`
- qemu fallback package:
  `qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb`
- packaging helpers:
  `fastboot.yaml`, `partition_2M.json`, `partition_flash.json`,
  `partition_universal.json`, `gen_imgcfg.py`

### What the Automation Builds

The current image build is configured for:

- board-profile selection through `build.conf` and optional `BOARD=...`
  overrides
- Bianbu 3.0.1 / `plucky`
- LXQt desktop image (`bianbu-desktop-lite`)
- source-mode kernel handling by default
- source-mode U-Boot handling by default
- packaged OpenSBI by default
- default locale `en_US.UTF-8`
- default timezone `America/Sao_Paulo`
- default user `eaie` with password `eaie`
- `root` password `eaie`
- SDDM autologin into `lxqt-wayland`
- `xterm`, `net-tools`, `qt6-wayland`, `cloud-guest-utils`,
  `openssh-server`, `ffmpeg`, `tpm2-tools`, and the YOLOv8 runtime stack baked
  into the image
- YOLOv8 runtime packages:
  `python3-numpy`, `python3-opencv`, `onnxruntime`, and
  `python3-spacemit-ort`
- TPM character-device access prepared through a `tss` group and udev rules
- SSH enabled by default, with development-only password login for both
  `eaie` and `root`
- an `8192M` rootfs image plus first-boot auto-expand
- an explicit `initrd.img-*` generation step before `bootfs.ext4` is packaged
- a dormant first-boot native repair helper retained for manual recovery work
- the repo wallpaper [screen.png](scripts/assets/screen.png) installed into
  `/usr/local/share/eaie-display-cycle/screen.png`
- the board-local demo runner installed as `/usr/local/bin/eaie-display-cycle`
- an LXQt launcher installed as `EAIE Display Cycle`

Calamares remains installed, but the OEM `initer` flow is disabled by replacing
SDDM autologin with the normal LXQt Wayland session.

Kernel/U-Boot mode behavior:

- repo defaults are loaded from [build.conf](build.conf)
- a plain `bash scripts/build-bianbu.sh` uses the current `build.conf`
  selections
- `BOARD=...`, `KERNEL_REBUILD=...`, `UBOOT_REBUILD=...`, `FULL_CLEAN=...`,
  and `SOURCE_ORIGIN=...` passed after the script name override `build.conf`
  for that invocation
- the current repo defaults are:
  - `BOARD=eaie-v1-riscv-spacemitk1`
  - `KERNEL_REBUILD=no`
  - `UBOOT_REBUILD=no`
  - `FULL_CLEAN=no`
- `SOURCE_ORIGIN=custom`
- `EAIE_CUSTOM_KERNEL_SOURCE_URL=git@github.com:gslm/linux-6.6-spacemit-k1.git`
- `EAIE_CUSTOM_KERNEL_SOURCE_REF=eaie-v1-riscv-spacemitk1`
- `EAIE_CUSTOM_UBOOT_SOURCE_URL=git@github.com:gslm/uboot-2022.10-spacemit-k1.git`
- `EAIE_CUSTOM_UBOOT_SOURCE_REF=eaie-v1-riscv-spacemitk1`
- `BOARD_HOST=192.168.28.85`
- `BOARD_USER=eaie`
- `BOARD_PASS=eaie`
- `BOARD_SSH_PORT=22`
- `AUTO_REBOOT=yes`
- source mode reuses source checkouts under `sources/` if they already exist
- source mode clones missing source trees and downloads the SpacemiT cross
  toolchain under `sources/toolchains/`
- when `KERNEL_REBUILD=no` and `UBOOT_REBUILD=no`, the build reuses the latest
  cached source-built Debian packages
- when `KERNEL_REBUILD=yes` and/or `UBOOT_REBUILD=yes`, the build rebuilds only
  the requested source packages on the host and then stages those package
  contents into the image rootfs before packaging
- `--kernel-default` and `--uboot-default` switch back to the packaged Bianbu
  kernel/U-Boot artifacts
- the current source path still keeps `opensbi-spacemit` from the packaged flow

The image does not ship with fixed SSH host keys. They are removed during image
creation and regenerated uniquely on first boot before `ssh.service` starts.

If the container build completes cleanly, the image boots normally.

Partial rootfs builds are not allowed. If package installation, package repair,
or required-runtime validation fails, the build aborts and the flashable
artifacts must be treated as invalid. The required runtime validation includes
the desktop profile, NetworkManager, SDDM, LXQt Wayland, SSH, rootfs expansion
tools, TPM userspace tools, and the YOLOv8 Python/NPU runtime.

Boot-critical note:

- the image must contain `initrd.img-6.6.63` in `bootfs`
- `bianbu-esos` installs an initramfs hook that injects
  `usr/lib/firmware/esos.elf` into the initrd
- without that initrd, the kernel can fail early in the `spacemit-rproc` path
  before the root filesystem is mounted

### Output Artifacts

The build writes these files at the repository root:

- [bianbu-custom.sdcard](bianbu-custom.sdcard)
- [bianbu-custom.zip](bianbu-custom.zip)
- [bootfs.ext4](bootfs.ext4)
- [rootfs.ext4](rootfs.ext4)

Each run also writes a full build log under `.bianbu-build/logs/` and updates
`.bianbu-build/logs/latest.log` to point at the newest log. Inspect that log
before flashing a new image.

### Adding Packages And Applications To The Image

Most image content is assembled in
[scripts/build-rootfs-in-container.sh](scripts/build-rootfs-in-container.sh).
Use that file as the source of truth for rootfs package and application
customization.

For Debian packages from the configured Bianbu/Ubuntu repositories:

- Add the package to `install_rootfs_packages()` in the appropriate
  `apt_install_chroot` call.
- If the package is required for a valid image, add it to
  `validate_required_runtime()` so the build fails instead of producing a
  partial image.
- If the package must be visible in the final `rootfs.ext4`, add a stable file
  path to `verify_generated_partition_images()`.
- If the package has mutually incompatible variants, document the selected
  package and avoid installing the conflicting one. Example: use
  `python3-spacemit-ort` for the SpacemiT NPU ONNXRuntime stack and do not add
  the generic `python3-onnxruntime` package.

For files or scripts maintained by this repository:

- Put static inputs under [scripts/assets/](scripts/assets/).
- Add or extend an installer function in
  `scripts/build-rootfs-in-container.sh`, such as `install_display_demo_assets()`
  or a new narrowly named function.
- Call that installer from `main()` through `run_timed_phase` so it appears in
  the build timing summary.
- Validate installed files either in the installer function itself or in
  `verify_generated_partition_images()` if the file must be present in the
  generated ext4 image.

For board-local test/demo applications:

- Prefer packaging prerequisites into the image, but keep experimental demo
  source payloads out of the base image until they are part of the product
  profile.
- Deploy temporary demo files over SSH during evaluation.
- Once a demo becomes part of the image, move its source files under
  `scripts/assets/` or a dedicated tracked directory and install them from a
  timed build phase.

Source workflow side effects:

- source checkouts live under `sources/`
- source-built Debian packages are written under `sources/kernel/` and
  `sources/u-boot/`
- the downloaded cross toolchain is kept under `sources/toolchains/`
- `FULL_CLEAN=yes` preserves source checkouts and the extracted toolchain, but
  removes the generated `.deb` build outputs and regular image staging state
- `FULL_CLEAN=yes` preserves `.bianbu-build/logs/` so failed rebuilds remain
  diagnosable

## Board Profile Model

The build system supports explicit board selection. The two important profiles
today are:

- `bpi-f3`
  The stock Banana Pi BPI-F3 baseline.
- `eaie-v1-riscv-spacemitk1`
  The EAIE custom-board profile.

The intended development model is:

- keep the stock board target bootable and usable as the reference baseline
- add EAIE-specific DTS and kernel changes under the EAIE board profile
- validate each custom-board step against the stock baseline

### Current EAIE Milestone

The model-only EAIE board-profile milestone is complete. The active milestone
keeps the stock BPI-F3 hardware baseline while adding a validated SPI TPM 2.0
bring-up path for the EAIE profile.

Current EAIE profile behavior:

- the EAIE DTS includes the stock `k1-x_deb1` common board description
- Linux reports `eaie-v1-riscv-spacemitk1` through `/proc/device-tree/model`
- SPI3 is enabled for an Infineon SLB9670 TPM 2.0 module
- the TPM module uses the native SPI3 chip select on physical header pin 24
- TPM reset and IRQ GPIOs are intentionally not modeled yet
- the kernel enables TPM, TPM HWRNG, and TPM TIS-over-SPI support
- the image includes `tpm2-tools` and grants TPM device access through `tss`

Validated board-side checks:

```bash
cat /proc/device-tree/model
ls -l /dev/tpm*
sudo tpm2_getrandom 8 --hex
```

### Current Runtime DTB Compatibility Note

The current stock U-Boot baseline still selects the runtime DTB by the stock
`product_name = k1-x_deb1` path. Because of that, the EAIE profile currently
keeps a runtime DTB alias so stock U-Boot can still boot while Linux uses the
EAIE board identity.

## Build Commands

Run from the repository root:

```bash
cd /media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom
```

Regular build using the defaults from [build.conf](build.conf):

```bash
bash scripts/build-bianbu.sh
```

Build for the stock BPI-F3 profile instead of the EAIE default:

```bash
bash scripts/build-bianbu.sh BOARD=bpi-f3
```

Rebuild only the kernel source package before packaging the image:

```bash
bash scripts/build-bianbu.sh KERNEL_REBUILD=yes
```

Rebuild only the U-Boot source package:

```bash
bash scripts/build-bianbu.sh UBOOT_REBUILD=yes
```

Full clean rebuild:

```bash
bash scripts/build-bianbu.sh FULL_CLEAN=yes
```

After a build, inspect the latest log before flashing:

```bash
less .bianbu-build/logs/latest.log
```

## Fast Deployment

For quick iteration after a source edit, the repo now has three fast deploy
paths that also read defaults from [build.conf](build.conf).

### Live Kernel Package Deploy

Reuses or rebuilds the source kernel Debian package, installs it on the live
board over SSH, synchronizes the selected board DTB into `/boot`, updates
`env_k1-x.txt`, and reboots by default:

```bash
bash scripts/deploy-live-kernel.sh
```

Rebuild the kernel package first:

```bash
bash scripts/deploy-live-kernel.sh KERNEL_REBUILD=yes
```

Skip the automatic reboot:

```bash
bash scripts/deploy-live-kernel.sh AUTO_REBOOT=no
```

### Live Kernel-DTB-only Deploy

Builds only the selected board DTB from the kernel source tree, copies it into
both `/usr/lib/linux-image-<version>/spacemit/` and `/boot/spacemit/<version>/`
on the live board, updates the runtime alias if needed, and reboots by default:

```bash
bash scripts/deploy-live-kernel-dtb.sh
```

This is the preferred path for small DTS-only experiments.

### U-Boot ITB Fast Deploy

Rebuilds `u-boot.itb` from the local U-Boot source tree, updates
`pack_dir/u-boot.itb`, and then flashes only the `uboot` partition through
fastboot:

```bash
bash scripts/deploy-uboot-itb.sh
```

If the host requires the newer Google platform-tools client:

```bash
bash scripts/deploy-uboot-itb.sh FASTBOOT_BIN="$HOME/platform-tools/fastboot"
```

### Deploy Defaults in build.conf

The live-deploy scripts currently use these defaults from
[build.conf](build.conf):

- `BOARD=eaie-v1-riscv-spacemitk1`
- `BOARD_HOST=192.168.28.85`
- `BOARD_USER=eaie`
- `BOARD_PASS=eaie`
- `BOARD_SSH_PORT=22`
- `AUTO_REBOOT=yes`

All of them can be overridden per invocation with `NAME=VALUE`.

The current EAIE custom source remotes are compact GitHub snapshot repos:

- kernel: `git@github.com:gslm/linux-6.6-spacemit-k1.git`
- U-Boot: `git@github.com:gslm/uboot-2022.10-spacemit-k1.git`

The original upstream remotes remain available through `SOURCE_ORIGIN=upstream`:

- kernel: `https://gitee.com/bianbu-linux/linux-6.6.git`
- U-Boot: `https://gitee.com/bianbu-linux/uboot-2022.10.git`

The local source trees live under:

- [sources/kernel/linux-6.6](sources/kernel/linux-6.6)
- [sources/u-boot/uboot-2022.10](sources/u-boot/uboot-2022.10)

The downloaded cross toolchain lives under:

- [sources/toolchains](sources/toolchains)

The build now reports:

- per-phase timing for host-side build stages
- per-phase timing for container-side build stages
- total host build time
- total container build time
- progress-aware copy reporting while generating `bootfs.ext4` and `rootfs.ext4`

## Flash Instructions

The eMMC fastboot flasher is:

- [scripts/eaie_flash.sh](scripts/eaie_flash.sh)

The bootfs-only recovery helper is:

- [scripts/repair-bootfs-initrd.sh](scripts/repair-bootfs-initrd.sh)

### Fastboot Client

Prefer the newer Google platform-tools `fastboot` client for this board. The
distro `fastboot` package can detect the device, but it has previously hung
during `fastboot stage` on this workflow.

Known-good local layout:

```text
$HOME/platform-tools/fastboot
```

This repository does not vendor Google platform-tools. Each developer should
install or unpack a recent platform-tools bundle locally so the binary is
available at the path above. If the bundle was extracted somewhere else, either
move it into `$HOME/platform-tools` or pass its `fastboot` path through
`FASTBOOT_BIN`.

Minimal local layout check:

```bash
test -x "$HOME/platform-tools/fastboot"
```

Check the active clients:

```bash
/usr/bin/fastboot --version
"$HOME/platform-tools/fastboot" --version
```

The flash script uses the system `fastboot` by default. Override it with
`FASTBOOT_BIN` whenever the local platform-tools client is available:

```bash
sudo env FASTBOOT_BIN="$HOME/platform-tools/fastboot" bash scripts/eaie_flash.sh
```

### Standard Flash Command

From the repository root:

```bash
sudo bash scripts/eaie_flash.sh
```

Recommended command when the local Google platform-tools client is available:

```bash
sudo env FASTBOOT_BIN="$HOME/platform-tools/fastboot" bash scripts/eaie_flash.sh
```

Use this command by default for full eMMC flashes. Only use the distro
`/usr/bin/fastboot` path when the local platform-tools client is unavailable.

If a full `rootfs` flash makes the development machine sluggish, use the
low-impact mode so `fastboot` runs at lower CPU and disk priority:

```bash
sudo env FASTBOOT_BIN="$HOME/platform-tools/fastboot" bash scripts/eaie_flash.sh --low-impact
```

### Manual Board Step

The board must be placed into ROM download mode manually:

1. Disconnect the board USB-C cable.
2. Hold `FDL` (`SW2`).
3. While holding `FDL`, insert the USB-C cable.
4. Release after the board is in download mode.

The script waits for `fastboot devices` to show a ready device, for example:

```text
dfu-device fastboot
```

### Serial Monitoring During Flashing

Run UART in a separate terminal if you want to watch the boot ROM and flash
interaction:

```bash
sudo picocom -b 115200 /dev/ttyUSB1
```

### What Gets Flashed

The current eMMC fastboot sequence is:

```text
fastboot stage factory/FSBL.bin
fastboot continue
fastboot stage u-boot.itb
fastboot continue
fastboot flash gpt partition_universal.json
fastboot flash bootinfo factory/bootinfo_emmc.bin
fastboot flash fsbl factory/FSBL.bin
fastboot flash env env.bin
fastboot flash opensbi fw_dynamic.itb
fastboot flash uboot u-boot.itb
fastboot flash bootfs bootfs.ext4
fastboot flash rootfs rootfs.ext4
fastboot reboot
```

### Bootfs-only Recovery

If only `bootfs` needs to be reflashed:

```bash
sudo bash scripts/eaie_flash.sh --bootfs-only
```

If only `u-boot.itb` needs to be reflashed:

```bash
sudo bash scripts/eaie_flash.sh --uboot-only
```

If the issue is a missing `initrd.img-*`, repair bootfs first:

```bash
sudo bash scripts/repair-bootfs-initrd.sh
sudo bash scripts/eaie_flash.sh --bootfs-only
```

## U-Boot & Kernel Development

Kernel, U-Boot, and device-tree development currently starts from the
source-built trees already integrated into this workspace.

### Current DTS and Defconfig Locations

Kernel-side board DTS entry points:

- EAIE custom-board wrapper:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts)
- stock BPI-F3 wrapper:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1.dts)
- shared common board file:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi)
- kernel DT Makefile:
  [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/Makefile](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/Makefile)

Kernel config entry points:

- current baseline defconfig:
  [sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig](sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig)
- current working build config after the first defconfig pass:
  [sources/kernel/linux-6.6/.config](sources/kernel/linux-6.6/.config)

U-Boot-side DT and config entry points:

- current U-Boot defconfig:
  [sources/u-boot/uboot-2022.10/configs/k1_defconfig](sources/u-boot/uboot-2022.10/configs/k1_defconfig)
- SPL default device tree selected by that defconfig:
  [sources/u-boot/uboot-2022.10/arch/riscv/dts/k1-x_spl.dts](sources/u-boot/uboot-2022.10/arch/riscv/dts/k1-x_spl.dts)
- current U-Boot proper board DT for the deb1 baseline:
  [sources/u-boot/uboot-2022.10/arch/riscv/dts/k1-x_deb1.dts](sources/u-boot/uboot-2022.10/arch/riscv/dts/k1-x_deb1.dts)
- current U-Boot boot environment that maps `product_name` to the Linux DTB:
  [sources/u-boot/uboot-2022.10/board/spacemit/k1-x/k1-x.env](sources/u-boot/uboot-2022.10/board/spacemit/k1-x/k1-x.env)

### Key DTS Entry Points

Stock BPI-F3 wrapper:

- [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1.dts)

EAIE custom-board wrapper:

- [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts)

Shared common board file:

- [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_deb1-common.dtsi)

Kernel DT Makefile:

- [sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/Makefile](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/Makefile)

### Current Edit Rules

Use these rules when deciding where to change things:

- edit `k1-x_deb1.dts` for stock BPI-F3-only identity
- edit `k1-x_eaie-v1-riscv-spacemitk1.dts` for EAIE custom-board identity
- edit `k1-x_deb1-common.dtsi` only if the change should affect both wrappers
- edit `k1-x.dtsi` only if the change should affect many K1-X boards
- edit subsystem `*.dtsi` files only when the change belongs to a shared block
  such as pinctrl, HDMI, LCD, camera, or thermal

### Basic Board Identity Check

After rebuilding or live-deploying the EAIE DTB, verify the board identity with:

```bash
cat /proc/device-tree/model
```

Expected runtime result:

```text
eaie-v1-riscv-spacemitk1
```

### SPI TPM 2.0 Bring-up

The current EAIE TPM target is an Infineon SLB9670 SPI TPM 2.0 module on SPI3.
The validated hardware setup uses the module's native chip-select option,
meaning the module 0R resistor is installed on `R7` so chip select is routed to
the BPI-F3 physical header pin 24.

Current DTS behavior:

- `&spi3` is enabled only in
  [k1-x_eaie-v1-riscv-spacemitk1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts)
- the TPM node uses `compatible = "infineon,slb9670"`
- `spi-max-frequency` is kept conservative at `1000000`
- reset and IRQ GPIOs are not described yet

Current kernel behavior:

- [k1_defconfig](sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig)
  enables `CONFIG_TCG_TPM`, `CONFIG_HW_RANDOM_TPM`, and
  `CONFIG_TCG_TIS_SPI`
- [tpm_tis_spi_main.c](sources/kernel/linux-6.6/drivers/char/tpm/tpm_tis_spi_main.c)
  routes SpacemiT K1X SPI controllers through the single-message TPM transfer
  path needed for correct TPM TIS flow-control behavior on this controller

Validated TPM probe indicators:

```text
tpm_tis_spi spi3.0: 2.0 TPM (device-id 0x1B, rev-id 22)
/dev/tpm0
/dev/tpmrm0
```

The lab-only helper
[scripts/tpm-spidev-read-registers.py](scripts/tpm-spidev-read-registers.py)
was used to prove that the module responds over raw SPI. It requires a
temporary spidev DTS/config setup and is not part of the production TPM path.

### MPU6050 IMU Bring-Up

The current lab bring-up DTS enables a temporary MPU6050 accelerometer/gyroscope
module on the external-header I2C bus. This is not the final production IMU; the
final EAIE hardware is expected to use an `LSM6DSO32TR`, which will need a
follow-up DTS and kernel-config change.

Current lab wiring:

- `AP_I2C4_SDA_3V3` / `AP_I2C4_SCL_3V3` for I2C
- I2C address `0x68`
- `GPIO_71_3v3`, physical header pin 11, for the optional interrupt line

Current kernel/DTS implementation:

- [k1-x_eaie-v1-riscv-spacemitk1.dts](sources/kernel/linux-6.6/arch/riscv/boot/dts/spacemit/k1-x_eaie-v1-riscv-spacemitk1.dts)
  enables the `imu@68` node under the active `i2c4` controller
- [k1_defconfig](sources/kernel/linux-6.6/arch/riscv/configs/k1_defconfig)
  enables `CONFIG_INV_MPU6050_IIO` and `CONFIG_INV_MPU6050_I2C`

Validated board-side checks:

```bash
cat /proc/device-tree/model && echo
find /proc/device-tree/soc/i2c@d4012800 -maxdepth 2 -print | grep 'imu@68'
sudo i2cget -y 4 0x68 0x75
ls -l /sys/bus/i2c/devices/4-0068/driver
for d in /sys/bus/iio/devices/iio:device*; do
  echo "== $d =="
  cat "$d/name"
done
```

Expected validation indicators:

```text
eaie-v1-riscv-spacemitk1
/proc/device-tree/soc/i2c@d4012800/imu@68
0x68
4-0068/driver -> .../inv-mpu6050-i2c
mpu6050
```

Useful raw sensor checks:

```bash
D=/sys/bus/iio/devices/iio:device1
cat "$D/in_accel_x_raw"
cat "$D/in_accel_y_raw"
cat "$D/in_accel_z_raw"
cat "$D/in_anglvel_x_raw"
cat "$D/in_anglvel_y_raw"
cat "$D/in_anglvel_z_raw"
```

### Current Runtime DTB Path

The staged runtime DTB currently lives under:

- `bootfs/spacemit/6.6.63/`

Boot selection is still driven through:

- `bootfs/env_k1-x.txt`

## Board FAQ

### Why does the display show video, but touch does not work?

Because `HDMI` and `USB` serve different roles:

- `HDMI` carries video only
- `USB` carries touch data
- `USB` often also powers the display

If the display USB cable is connected to the development machine instead of the
board, touch events go to the development machine, not to the BPI-F3.

### Correct HDMI Touch Display Wiring

Recommended wiring:

- board `HDMI` to display `HDMI` for video
- display `USB` to board `USB` for touch data

If the display needs more power than the board can comfortably provide, use an
external `5V` power supply, but still keep a USB data path between the display
and the board. Power alone is not enough for touch.

### How Do I Verify Touch Input?

Run on the board:

```bash
lsusb
libinput list-devices
```

If touch is connected correctly, a touchscreen/input device should appear.

### Why Does the Camera Path Keep Changing?

Raw `/dev/videoN` numbers are not stable. The camera can re-enumerate and come
back as a different device number.

Use the stable symlink under `/dev/v4l/by-id/` instead. For the currently
validated webcam in this project:

```bash
/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0
```

Use `video-index0` for the image stream. `video-index1` is metadata, not the
main preview stream.

### Why Does the USB Camera Sometimes Freeze or Disappear?

The observed failures were consistent with USB link or power instability, not
with `ffplay` itself. Typical symptoms included:

- `VIDIOC_DQBUF: No such device`
- `usb_set_interface failed (-71)`
- `can't set config #1, error -71`

When those appear, check:

- cable quality
- power stability
- hub topology
- whether the camera is sharing an unstable USB path

## References

- Banana Pi BPI-F3 main documentation:
  <https://docs.banana-pi.org/en/BPI-F3/BananaPi_BPI-F3>
  This page includes the `GPIO Pin Define` section used as the primary header
  pinout reference for the stock BPI-F3 board.

## TODO's

- Validate the EAIE board profile on the first real EAIE custom hardware when
  that board is available.
- Evaluate when the stock U-Boot compatibility alias is no longer sufficient
  and introduce EAIE-specific U-Boot changes at that point.
- Model TPM reset and IRQ GPIOs after the hardware wiring is finalized.
- Replace the temporary MPU6050 lab IMU node with the production
  `LSM6DSO32TR` IMU when the final hardware design is ready.
- Expand the kernel changes tutorial as more DTS, driver, and kernel-config
  work lands in this repo.
- Use the new timing and progress reporting to identify the slowest build
  phases and optimize them.
- Split the kernel workflow into separate full-package and fast-iteration
  paths: keep Debian package generation for reproducible image builds, but add
  a lightweight kernel/DTB/module build path for live board bring-up without
  rebuilding all kernel Debian packages.
- Move the full build flow into a Docker-contained workflow so the entire build
  environment is containerized.
- Once the custom kernel and rootfs workspaces are the primary development
  inputs, use `repo` to synchronize the required workspaces into the build
  container.
