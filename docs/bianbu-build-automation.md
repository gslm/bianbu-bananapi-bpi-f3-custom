# Bianbu Build Automation

## Overview

The automation for this workspace is split into:

- [scripts/build-bianbu.sh](../scripts/build-bianbu.sh): host-side orchestration
- [scripts/build-rootfs-in-container.sh](../scripts/build-rootfs-in-container.sh): container-side rootfs and image build
- [scripts/assets/expand-rootfs.sh](../scripts/assets/expand-rootfs.sh): first-boot rootfs grow helper
- [scripts/assets/expand-rootfs.service](../scripts/assets/expand-rootfs.service): systemd unit that runs the grow helper once

The automation is pinned to the exact versions already used in this workspace:

- builder image: `harbor.spacemit.com/bianbu/bianbu@sha256:96ada91d222fab6ab676464e622d7f5dd49f8f4b747a13fae61f3134f1547400`
- base rootfs: `bianbu-base-25.04.2-base-riscv64.tar.gz`
- qemu host package: `qemu-user-static_8.0.4+dfsg-1ubuntu3.23.10.1_amd64.deb`
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
- default locale `en_US.UTF-8`
- default timezone `America/Sao_Paulo`
- default user `eaie` with password `eaie`
- `root` password `eaie`
- SDDM autologin into `lxqt-wayland`
- `xterm`, `net-tools`, `qt6-wayland`, `cloud-guest-utils`, and `openssh-server` baked into the image
- SSH enabled by default, with development-only password login for both `eaie` and `root`
- an `8192M` rootfs image plus first-boot auto-expand

Calamares is kept installed, but the OEM `initer` flow is disabled by replacing
SDDM autologin with the normal LXQt Wayland session.

The image does not ship with fixed SSH host keys. They are removed during image
creation and regenerated uniquely on first boot before `ssh.service` starts.

## Usage

Run from the repository root:

```bash
bash scripts/build-bianbu.sh
```

To fully reset the build state first:

```bash
bash scripts/build-bianbu.sh --clean
```

## Output Artifacts

The script writes these files at the repository root:

- [bianbu-custom.sdcard](../bianbu-custom.sdcard)
- [bianbu-custom.zip](../bianbu-custom.zip)

It also regenerates at the repository root:

- [bootfs.ext4](../bootfs.ext4)
- [rootfs.ext4](../rootfs.ext4)

## Notes

- The automation fails hard if the container build still leaves `dpkg` in a
  broken state or if the Qt6 Wayland plugin is missing.
- Autologin, password SSH, and the `eaie` passwords are development-only defaults.
- `--clean` removes the build staging tree, generated images, pinned downloads,
  and builder containers whose names start with `build-bianbu-rootfs`.
