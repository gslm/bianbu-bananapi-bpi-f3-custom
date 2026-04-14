# Bianbu Repo Handoff

## Scope

This repository captures the reusable scripts, documentation, and test assets
produced while bringing up a stock Bianbu 3.0.1 image for the Banana Pi BPI-F3.
The original image build and deployment work was done from the surrounding
workspace, and this repo now holds the reusable parts of that work.

The current state proves all of the following:

- a Bianbu Ubuntu-based LXQt image can be generated in this workspace
- the SD card image and Titan flash zip can both be generated
- the eMMC fastboot flashing path is validated through a full boot to login
- the booted image can be customized in userspace without rebuilding from
  scratch for every small test
- the display stack issue was traced to a missing Qt6 Wayland runtime plugin
- a DTB can be replaced on the target and picked up successfully at next boot

## What We Successfully Changed

### 1. Image defaults and userspace customization

We defined and documented a customized image profile with:

- locale: `en_US.UTF-8`
- timezone: `America/Sao_Paulo`
- desktop: `bianbu-desktop-lite`
- default user: `eaie`
- default password: `eaie`
- root password: `eaie`
- autologin enabled for development
- SSH enabled by default for development images

### 2. GUI bring-up fix

The booted image initially reached HDMI and SDDM, but the greeter crashed due
to a missing Qt6 Wayland platform plugin.

Validated fix:

- install `qt6-wayland`

This was folded into the new image automation so future builds should not ship
with the same runtime gap.

### 3. Package/dependency repair guidance

The original desktop image had an incomplete package state caused during the
containerized riscv64 package-install phase.

We documented:

- how to repair the package database
- how to validate that `dpkg` is fully clean
- how to ensure the Qt6 Wayland platform plugin is present before packaging an
  image

### 4. Boot-logo experimentation

We identified the active boot logo asset in the build workspace at:

- `bootfs/bianbu.bmp`

We also tested replacing that asset with a converted EAIE bitmap that is now
stored in this repo:

- [eaie-256-ffmpeg.bmp](../eaie-256-ffmpeg.bmp)

The backup of the original boot logo remains a local workspace artifact:

- `bianbu.bmp.backup`

### 5. DTB redeploy workflow

We proved that the board accepts a replaced DTB from `/boot` and reflects the
change after reboot.

Validated change:

- original model string:
  `spacemit k1-x deb1 board`
- updated model string:
  `eaie-1.0 board`

Patched files in the build workspace:

- `bootfs/spacemit/6.6.63/k1-x_deb1.dtb`
- `rootfs/usr/lib/linux-image-6.6.63/spacemit/k1-x_deb1.dtb`

This gives us a fast DTS-only deployment loop over SSH for future board work.

### 6. eMMC flashing and missing-initrd recovery

We added a host-side fastboot flasher for the BPI-F3 eMMC path and validated
that it can drive the board through ROM download mode, complete the staged
flash sequence, and boot the resulting eMMC image to a login prompt.

During the first full eMMC boot attempt, the image exposed a separate bug:

- `bootfs` was missing `initrd.img-6.6.63`
- U-Boot fell back to a built-in ramdisk
- the kernel then failed to load `esos.elf`
- the board stalled early in the `spacemit-rproc` path

Mitigations now captured in the repo:

- the build automation explicitly generates `initrd.img-*` before packaging
  `bootfs.ext4`
- the build refuses to package `bootfs` if no initrd is present
- a dedicated recovery helper can regenerate the initrd and rebuild only
  `bootfs.ext4`
- the flasher now treats unsupported `fastboot reboot` as a board quirk and
  falls back to manual reset instead of reporting a false flash failure

There was also a host-side tooling issue on the current Ubuntu 22.04 machine:

- distro `fastboot 28.0.2-debian` detected the board but hung on
  `fastboot stage factory/FSBL.bin`
- the validated working client was Google Android platform-tools `fastboot`
- `scripts/eaie_flash.sh` now accepts `FASTBOOT_BIN=/path/to/fastboot`

Validated first eMMC-boot baseline:

- machine model remained stock: `spacemit k1-x deb1 board`
- hostname remained stock: `host1`
- login prompt appeared on serial at about 189 seconds
- login as `eaie` succeeded

That is the clean pre-device-tree baseline for future board customization.

## Reusable Files Now In This Repo

These are the main source artifacts now present in the Git repo.

### Scripts

- [scripts/build-bianbu.sh](../scripts/build-bianbu.sh)
- [scripts/build-rootfs-in-container.sh](../scripts/build-rootfs-in-container.sh)
- [scripts/eaie_flash.sh](../scripts/eaie_flash.sh)
- [scripts/repair-bootfs-initrd.sh](../scripts/repair-bootfs-initrd.sh)
- [scripts/patch-dtb-model.sh](../scripts/patch-dtb-model.sh)

### Script assets

- [scripts/assets/expand-rootfs.sh](../scripts/assets/expand-rootfs.sh)
- [scripts/assets/expand-rootfs.service](../scripts/assets/expand-rootfs.service)
- [scripts/assets/ssh-hostkeys.service](../scripts/assets/ssh-hostkeys.service)
- [scripts/assets/firstboot-repair.sh](../scripts/assets/firstboot-repair.sh)
- [scripts/assets/firstboot-repair.service](../scripts/assets/firstboot-repair.service)

### Documentation

- [docs/bianbu-image-update-instructions.md](./bianbu-image-update-instructions.md)
- [docs/bianbu-build-automation.md](./bianbu-build-automation.md)
- [docs/emmc-flashing.md](./emmc-flashing.md)
- [docs/development-handoff.md](./development-handoff.md)
- [docs/repo-handoff.md](./repo-handoff.md)

### Repo test asset

- [eaie-256-ffmpeg.bmp](../eaie-256-ffmpeg.bmp)

## Important Files Modified Outside This Repo

These files were intentionally modified during bring-up, but they still live in
the local build workspace rather than in this repo.

- `bootfs/bianbu.bmp`
- `bootfs/spacemit/6.6.63/k1-x_deb1.dtb`
- `rootfs/usr/lib/linux-image-6.6.63/spacemit/k1-x_deb1.dtb`

## Files That Are Generated, Downloaded, Or Local-Test Artifacts

These should generally not be committed to this repo unless you intentionally
want to vendor large binaries into version control.

### Generated images and staging outputs

- `bianbu-custom.sdcard`
- `bianbu-custom.zip`
- `bootfs.ext4`
- `rootfs.ext4`
- `pack_dir/`
- `rootfs/`
- `bootfs/` except for explicitly tracked curated assets

### Downloaded inputs

- `bianbu-base-25.04.2-base-riscv64.tar.gz`
- `qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb`
- `rvv`

### Local test and scratch files

- `.bianbu-build/`
- `0001-first-boot.log`
- `0002-hdmi.log`
- `0003-first-clean-run.log`
- `0004-kernel-boot-error.log`
- `eaie.bmp`
- `eaie-256.bmp`
- `eaie-256-ffmpeg.bmp`
- `BMP4:eaie-256-32.bmp`
- `bianbu.bmp.backup`

## Recommended Initial Commit Scope

If the goal is a clean repo that captures process, reusable tooling, and the
logo test asset, the recommended first commit is:

- `scripts/`
- `docs/`
- `eaie-256-ffmpeg.bmp`

If the goal is to also preserve the current tested board-specific build
artifacts, first move them into the repo and then additionally include:

- `bootfs/bianbu.bmp`
- `bootfs/spacemit/6.6.63/k1-x_deb1.dtb`
- `rootfs/usr/lib/linux-image-6.6.63/spacemit/k1-x_deb1.dtb`

## Suggested Next Git Step

After you create the repo and add the remote, the next useful step would be to
add a `.gitignore` that excludes:

- generated images
- downloaded tarballs and `.deb`s
- temporary build state
- raw logs
- container staging output

That keeps the repo focused on scripts, docs, and intentional board assets.
