# Development Handoff

## Purpose

This document is the full continuity note for the next development cycle on a
different machine. It captures the working assumptions, the validated results,
the known risks, and the expected next steps for continuing Bianbu bring-up and
customization on the Banana Pi BPI-F3.

This repo contains the reusable scripts, documentation, and a boot-logo test
asset. The larger build workspace, generated images, rootfs staging tree, and
live board state are not fully versioned here.

## Target Summary

- SoC: SpacemiT K1 / K1-X family
- Current board target: stock Banana Pi BPI-F3
- Future direction: custom BF-3-derived board
- Current distro target: Bianbu 3.0.1, Ubuntu-based, package-managed
- Current desktop target: LXQt via `bianbu-desktop-lite`

## High-Level Conclusions From This Cycle

### 1. Bianbu is not a Buildroot-style flow

The original confusion came from expecting a Buildroot or Yocto layout with
separate first-class source trees for:

- U-Boot
- kernel
- rootfs

The Bianbu 3.0 workflow used here is package-centric instead:

- the rootfs is assembled from Debian packages
- bootloader and kernel artifacts are also packaged
- the image packaging stage pulls those artifacts from the populated rootfs

Practical consequence:

- small DTS-only experiments do not require a full kernel rebuild
- kernel config, driver, and module work still require a real kernel build path
- early bootloader or board-init changes are a separate layer

### 2. The current Bianbu rootfs is Ubuntu-based, not Debian proper

Validated through `/etc/os-release` on the live board:

- `ID=bianbu`
- `ID_LIKE=debian`
- `UBUNTU_CODENAME=plucky`

So the correct mental model is:

- Bianbu distro identity
- Ubuntu-derived base
- Debian-family package semantics

### 3. We successfully built and booted a stock BPI-F3 image

Confirmed:

- SD image packaging works
- Titan flash zip packaging works
- the board boots the generated image
- serial console works
- userspace login works
- HDMI and desktop can work after fixing the missing runtime dependency

### 4. Device tree redeploy is now a validated fast loop

We successfully changed:

- `/proc/device-tree/model`

From:

```text
spacemit k1-x deb1 board
```

To:

```text
eaie-1.0 board
```

This was achieved by replacing the active DTB used by the booted system and
rebooting. That validates a very useful rapid inner loop for future board DTS
work.

## Upstream References Used

These were the primary references for the work captured in this repo.

### Board and platform references

- Banana Pi BPI-F3 overview
- Banana Pi BPI-F3 getting started
- SpacemiT K1 platform documentation

### Bianbu references

- Bianbu 3.0 rootfs creation guide
- Bianbu image creation guide
- Bianbu kernel compile guide

These URLs were used during the session:

- `https://docs.banana-pi.org/en/BPI-F3/BananaPi_BPI-F3`
- `https://docs.banana-pi.org/en/BPI-F3/GettingStarted_BPI-F3`
- `https://www.spacemit.com/community/document/info?lang=zh&nodepath=hardware/key_stone/k1/k1_docs/root_overview.md`
- `https://www.spacemit.com/community/document/info?lang=zh&nodepath=software/SDK/bianbu/system_integration/bianbu_3.0_rootfs_create.md`
- `https://www.spacemit.com/community/document/info?nodepath=software/SDK/bianbu/system_integration/image.md&lang=zh`
- `https://www.spacemit.com/community/document/info?lang=zh&nodepath=software/SDK/bianbu/development/kernel_compile.md`

## What Was Actually Validated On Hardware

### Boot and serial

Validated:

- the generated SD image boots on the BPI-F3
- serial console output appears normally
- the image targets the expected BPI-F3 profile through `k1-x_deb1`

### Package management

Validated:

- `apt` is the standard package manager in practice
- `dpkg` state can be repaired on the live board
- `net-tools` was installed successfully
- locale was changed successfully on the live board

### Desktop and HDMI

Observed:

- HDMI and SDDM came up, but the greeter crashed initially
- the root cause was a missing Qt6 Wayland platform plugin

Validated fix:

- installing `qt6-wayland` fixed the GUI

### SSH

Observed:

- SSH behavior on the live board was not initially aligned with the expected
  development flow
- root SSH with password was not reliably available by default

Repo-level fix now added:

- the automated image flow installs `openssh-server`
- password-based SSH is enabled for development images
- host keys are regenerated uniquely on first boot

### Boot logo

Validated:

- the boot logo asset can be identified and replaced for testing

The converted test logo stored in this repo is:

- [eaie-256-ffmpeg.bmp](../eaie-256-ffmpeg.bmp)

### DTS-only change

Validated:

- a patched DTB redeployed to the board is used on next boot
- the DTB `model` change is reflected at runtime

This is the most important technical result for upcoming custom-board work.

## Working Development Defaults

These are intentionally insecure and are meant only for bring-up and internal
development.

- default user: `eaie`
- default user password: `eaie`
- root password: `eaie`
- SDDM autologin enabled
- SSH password login enabled
- root SSH login enabled

These defaults must be revisited before any production, customer, or remotely
exposed deployment.

## Repo Contents

### Main automation scripts

- [scripts/build-bianbu.sh](../scripts/build-bianbu.sh)
- [scripts/build-rootfs-in-container.sh](../scripts/build-rootfs-in-container.sh)
- [scripts/patch-dtb-model.sh](../scripts/patch-dtb-model.sh)

### Supporting systemd/service assets

- [scripts/assets/expand-rootfs.sh](../scripts/assets/expand-rootfs.sh)
- [scripts/assets/expand-rootfs.service](../scripts/assets/expand-rootfs.service)
- [scripts/assets/ssh-hostkeys.service](../scripts/assets/ssh-hostkeys.service)

### Documentation

- [docs/bianbu-build-automation.md](./bianbu-build-automation.md)
- [docs/bianbu-image-update-instructions.md](./bianbu-image-update-instructions.md)
- [docs/repo-handoff.md](./repo-handoff.md)
- [docs/development-handoff.md](./development-handoff.md)

## Build Flow Captured In The Repo

### Host-side orchestration

`scripts/build-bianbu.sh` is responsible for:

- checking/installing host prerequisites
- pulling the pinned Docker builder image
- downloading pinned upstream inputs
- installing the pinned host `qemu-user-static`
- creating or reusing the privileged build container
- running the in-container rootfs and image build

It also supports:

- `--clean`

Which removes prior container/build state and starts from scratch.

### Container-side build logic

`scripts/build-rootfs-in-container.sh` is responsible for:

- unpacking the pinned base rootfs
- writing the pinned Bianbu apt source configuration
- installing the standard boot/kernel packages
- installing `bianbu-desktop-lite`
- installing customization packages such as:
  - `qt6-wayland`
  - `xterm`
  - `net-tools`
  - `cloud-guest-utils`
  - `openssh-server`
- fixing locale and timezone
- creating the `eaie` user and setting passwords
- switching SDDM away from the OEM `Calamares` flow
- enabling the first-boot rootfs growth service
- generating:
  - `bootfs.ext4`
  - `rootfs.ext4`
  - `bianbu-custom.sdcard`
  - `bianbu-custom.zip`

### DTB patch helper

`scripts/patch-dtb-model.sh` provides a very small experimental workflow for
changing just the top-level `model` property of a DTB. It is intended for DTS
experiments, not as a substitute for a real kernel source workflow.

## Important Pinned Inputs

The automation is pinned to the exact versions used during this cycle.

### Builder image

- `harbor.spacemit.com/bianbu/bianbu@sha256:96ada91d222fab6ab676464e622d7f5dd49f8f4b747a13fae61f3134f1547400`

### Base rootfs

- `bianbu-base-25.04.2-base-riscv64.tar.gz`

### Host qemu package

- `qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb`

### Firmware helper inputs

- `fastboot.yaml`
- `partition_2M.json`
- `partition_flash.json`
- `partition_universal.json`
- `gen_imgcfg.py`

## Known Risks And Caveats

### 1. qemu/chroot package-install fragility

Earlier in the cycle, the containerized rootfs install hit riscv64 package
failures during desktop package installation.

Observed examples included failures around:

- `modemmanager`
- `fonts-lohit-taml-classical`
- `speech-dispatcher`

The new automation is intentionally strict:

- if package state remains broken, it fails hard
- if the Qt6 Wayland runtime is missing, it fails hard

That is correct behavior, but the underlying container/qemu path may still need
further investigation if these failures reappear on a fresh machine.

### 2. The rootfs auto-expand service is automated but not yet revalidated end to end

The repo now includes a first-boot rootfs expansion path using:

- `growpart`
- `resize2fs`

This design is sound for the target layout, but it still needs validation with
a newly generated image from the scripted flow.

### 3. The SSH defaults are intentionally insecure

Password SSH and root login were enabled because the immediate goal is rapid
bring-up and deployment. This is acceptable for internal development but should
be treated as temporary.

### 4. DTB patching is not yet the long-term kernel workflow

The DTB redeploy path is excellent for bring-up, but it does not replace the
need for a proper kernel source tree when you move beyond trivial DTS edits.

The next kernel milestone should be:

- bring in the actual SpacemiT kernel source tree
- patch the DTS in source form
- build reproducible kernel artifacts or packages

## Exact Practical Lessons From This Cycle

### Boot logo test path

For quick boot-logo experiments:

- replace the boot logo file
- rebuild the image or replace the live `/boot` asset
- reboot and observe boot splash behavior

### DTS-only test path

For quick device-tree experiments:

1. patch the active DTB
2. copy the DTB to the live board
3. replace the file under `/boot/spacemit/<kernel-version>/`
4. reboot
5. validate through `/proc/device-tree/...`

This is now a confirmed working loop.

### Live board vs generated image

The live board used during the session was modified interactively in several
places:

- locale changes
- package installation
- password changes
- DTB replacement
- boot-logo testing

Do not assume the current live board exactly matches what the scripted image
flow will produce until the new scripts are run from scratch and the resulting
image is boot-tested.

## Recommended Next Steps On The New Machine

### First priority

Run the new automation from scratch on a clean machine and validate:

- Docker access
- pinned downloads
- host qemu registration
- rootfs creation
- package-state cleanup
- image generation

### Second priority

Boot the newly scripted image and confirm:

- serial login
- locale defaults
- timezone
- desktop autologin
- HDMI/GUI
- SSH availability
- first-boot rootfs expansion

### Third priority

Verify board-level development loops:

- SSH file deployment
- DTB redeploy
- boot-logo replacement

### Fourth priority

Start the real kernel-source workflow for persistent DTS changes and future
driver/module/config work.

## Suggested Immediate Checklist For Tomorrow

1. Clone this repo on the new machine.
2. Review `docs/bianbu-build-automation.md`.
3. Run `bash scripts/build-bianbu.sh --clean`.
4. If the build fails, capture the exact failing package or stage.
5. If it succeeds, flash and boot the generated SD image.
6. Validate GUI, SSH, and rootfs expansion.
7. Only after that, move on to real kernel-source integration.

## Final State At End Of This Cycle

At the end of this cycle, the important technical position is:

- image build process understood
- automation created
- GUI runtime issue diagnosed and folded into automation
- SSH enablement folded into automation
- boot-logo testing path understood
- DTB redeploy validated on hardware

That is a strong baseline for the next iteration.
