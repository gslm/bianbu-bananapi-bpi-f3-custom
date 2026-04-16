# Bianbu Build Automation

## Overview

The automation for this workspace is split into:

- [scripts/build-bianbu.sh](../scripts/build-bianbu.sh): host-side orchestration
- [scripts/build-source-artifacts.sh](../scripts/build-source-artifacts.sh): host-side kernel/U-Boot source checkout and package build helper
- [scripts/build-rootfs-in-container.sh](../scripts/build-rootfs-in-container.sh): container-side rootfs and image build
- [scripts/eaie_flash.sh](../scripts/eaie_flash.sh): host-side eMMC fastboot flasher
- [scripts/run-display-cycle-local.sh](../scripts/run-display-cycle-local.sh): board-local HDMI demo loop
- [scripts/assets/expand-rootfs.sh](../scripts/assets/expand-rootfs.sh): first-boot rootfs grow helper
- [scripts/assets/expand-rootfs.service](../scripts/assets/expand-rootfs.service): systemd unit that runs the grow helper once
- [scripts/assets/firstboot-repair.sh](../scripts/assets/firstboot-repair.sh): first-boot native package-repair helper
- [scripts/assets/firstboot-repair.service](../scripts/assets/firstboot-repair.service): systemd unit that repairs a partial image on the board
- [scripts/assets/eaie-display-cycle.desktop](../scripts/assets/eaie-display-cycle.desktop): LXQt launcher for the built-in HDMI demo loop

The automation is pinned to the exact versions already used in this workspace,
except for host `qemu-user-static`, which is now handled in auto mode:

- builder image: `harbor.spacemit.com/bianbu/bianbu@sha256:96ada91d222fab6ab676464e622d7f5dd49f8f4b747a13fae61f3134f1547400`
- base rootfs: `bianbu-base-25.04.2-base-riscv64.tar.gz`
- qemu fallback package: `qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb`
- firmware helper inputs:
  - `fastboot.yaml`
  - `partition_2M.json`
  - `partition_flash.json`
  - `partition_universal.json`
  - `gen_imgcfg.py`

## What The Automation Builds

The build is configured for:

- BPI-F3 stock board target
- Bianbu 3.0.1 / `plucky`
- LXQt desktop image (`bianbu-desktop-lite`)
- source-built kernel by default
- source-built U-Boot by default
- packaged OpenSBI by default
- default locale `en_US.UTF-8`
- default timezone `America/Sao_Paulo`
- default user `eaie` with password `eaie`
- `root` password `eaie`
- SDDM autologin into `lxqt-wayland`
- `xterm`, `net-tools`, `qt6-wayland`, `cloud-guest-utils`, `openssh-server`, and `ffmpeg` baked into the image
- SSH enabled by default, with development-only password login for both `eaie` and `root`
- an `8192M` rootfs image plus first-boot auto-expand
- a native first-boot repair path if qemu leaves the rootfs in a partial state during the container build
- an explicit `initrd.img-*` generation step before `bootfs.ext4` is packaged
- the repo wallpaper [screen.png](../screen.png) installed into `/usr/local/share/eaie-display-cycle/screen.png`
- the board-local demo runner installed as `/usr/local/bin/eaie-display-cycle`
- an LXQt application launcher for the display demo installed as `EAIE Display Cycle`
- LXQt system wallpaper defaults updated so first boot uses the repo wallpaper

Calamares is kept installed, but the OEM `initer` flow is disabled by replacing
SDDM autologin with the normal LXQt Wayland session.

Kernel/U-Boot mode behavior:

- `scripts/build-bianbu.sh` now defaults to `--kernel-mode source --uboot-mode source`
- source mode reuses source checkouts under `sources/` if they already exist
- source mode clones missing source trees and downloads the SpacemiT cross toolchain under `sources/toolchains/`
- source mode builds Debian packages from source on the host, then stages those package contents into the image rootfs before packaging
- `--kernel-default` and `--uboot-default` switch back to the packaged Bianbu kernel/U-Boot artifacts
- the current source path still keeps `opensbi-spacemit` from the packaged flow

The image does not ship with fixed SSH host keys. They are removed during image
creation and regenerated uniquely on first boot before `ssh.service` starts.

If the container build completes cleanly, the image boots normally.

If the container build hits the known qemu/riscv64 package-install problem, the
automation now packages a provisional image as long as the required bootloader
and kernel artifacts were installed. On first boot, the board runs
`eaie-firstboot-repair.service`, repairs the package state natively, applies the
final locale/timezone/runtime package configuration, and then reboots once.

Boot-critical note:

- the image must contain `initrd.img-6.6.63` in `bootfs`
- `bianbu-esos` installs an initramfs hook that injects `usr/lib/firmware/esos.elf`
  into the initrd
- without that initrd, the kernel can fail early in the `spacemit-rproc` path
  before the root filesystem is mounted

## Usage

Run from the repository root:

```bash
bash scripts/build-bianbu.sh
```

To fully reset the build state first:

```bash
bash scripts/build-bianbu.sh --clean
```

To force the old fully packaged BSP path:

```bash
bash scripts/build-bianbu.sh --kernel-default --uboot-default
```

To mix a source-built kernel with the packaged bootloader:

```bash
bash scripts/build-bianbu.sh --uboot-default
```

## Output Artifacts

The script writes these files at the repository root:

- [bianbu-custom.sdcard](../bianbu-custom.sdcard)
- [bianbu-custom.zip](../bianbu-custom.zip)

It also regenerates at the repository root:

- [bootfs.ext4](../bootfs.ext4)
- [rootfs.ext4](../rootfs.ext4)

Source workflow side effects:

- source checkouts live under `sources/`
- source-built Debian packages are written under `sources/kernel/` and `sources/u-boot/`
- the downloaded cross toolchain is kept under `sources/toolchains/`
- `--clean` preserves source checkouts and the extracted toolchain, but removes the generated `.deb` build outputs and regular image staging state

For eMMC flashing after the build, see:

- [docs/emmc-flashing.md](./emmc-flashing.md)

## Built-In Display Demo

New images now include a board-local HDMI demo loop:

```bash
eaie-display-cycle
```

By default it runs:

- camera preview for 60 seconds
- fullscreen test-pattern screensaver for 30 seconds
- normal desktop with the repo wallpaper for 30 seconds

The built-in wallpaper path is:

- `/usr/local/share/eaie-display-cycle/screen.png`

Example with shorter timings:

```bash
eaie-display-cycle --camera-seconds 10 --screensaver-seconds 10 --desktop-seconds 10
```

## Notes

- The host-side script now prefers the system `qemu-user-static` if it passes
  the SpacemiT `rvv` check. It falls back to the older pinned SpacemiT package
  only if the host runtime does not work.
- The current Ubuntu 22.04 development machine required Google Android
  platform-tools `fastboot` for eMMC flashing because distro
  `fastboot 28.0.2-debian` hung on `fastboot stage factory/FSBL.bin`.
  `scripts/eaie_flash.sh` supports `FASTBOOT_BIN=/path/to/fastboot` for this.
- The automation no longer assumes the container build can always finish the
  desktop stack cleanly. It can package a provisional image that repairs itself
  natively on first boot.
- Autologin, password SSH, and the `eaie` passwords are development-only defaults.
- `--clean` removes the build staging tree, generated images, pinned downloads,
  and builder containers whose names start with `build-bianbu-rootfs`.
