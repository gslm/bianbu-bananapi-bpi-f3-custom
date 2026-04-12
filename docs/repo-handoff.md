# Bianbu Repo Handoff

## Scope

This repository captures the reusable scripts, documentation, and test assets
produced while bringing up a stock Bianbu 3.0.1 image for the Banana Pi BPI-F3.
The original image build and deployment work was done from the surrounding
workspace, and this repo now holds the reusable parts of that work.

The current state proves all of the following:

- a Bianbu Ubuntu-based LXQt image can be generated in this workspace
- the SD card image and Titan flash zip can both be generated
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

## Reusable Files Now In This Repo

These are the main source artifacts now present in the Git repo.

### Scripts

- [scripts/build-bianbu.sh](../scripts/build-bianbu.sh)
- [scripts/build-rootfs-in-container.sh](../scripts/build-rootfs-in-container.sh)
- [scripts/patch-dtb-model.sh](../scripts/patch-dtb-model.sh)

### Script assets

- [scripts/assets/expand-rootfs.sh](../scripts/assets/expand-rootfs.sh)
- [scripts/assets/expand-rootfs.service](../scripts/assets/expand-rootfs.service)
- [scripts/assets/ssh-hostkeys.service](../scripts/assets/ssh-hostkeys.service)

### Documentation

- [docs/bianbu-image-update-instructions.md](./bianbu-image-update-instructions.md)
- [docs/bianbu-build-automation.md](./bianbu-build-automation.md)
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
