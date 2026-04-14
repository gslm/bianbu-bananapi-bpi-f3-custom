# eMMC Flashing

## Overview

The repository contains a host-side fastboot flasher for the generated BPI-F3
eMMC image package:

- [scripts/eaie_flash.sh](../scripts/eaie_flash.sh)
- [scripts/repair-bootfs-initrd.sh](../scripts/repair-bootfs-initrd.sh)

This script is meant for the generated files already present in:

- [pack_dir](../pack_dir)

It automates:

- installation of the BPI-F3 DFU udev rule
- udev reload
- detection of the board in DFU download mode
- the staged `fastboot` flashing sequence for eMMC

Important host note:

- on the current Ubuntu 22.04 development machine, Debian/Ubuntu
  `fastboot 28.0.2-debian` reached device detection but hung on
  `fastboot stage factory/FSBL.bin`
- the validated working client was the current Google Android platform-tools
  `fastboot`
- `scripts/eaie_flash.sh` supports `FASTBOOT_BIN=/path/to/fastboot` for this
  reason

## Usage

Run from the repository root:

```bash
sudo bash scripts/eaie_flash.sh
```

Recommended on hosts where the distro `fastboot` hangs during `stage`:

```bash
sudo env FASTBOOT_BIN="$HOME/platform-tools/fastboot" bash scripts/eaie_flash.sh
```

If you want UART output while flashing, run serial in a separate terminal:

```bash
sudo picocom -b 115200 /dev/ttyUSB1
```

Bootfs-only recovery:

```bash
sudo bash scripts/eaie_flash.sh --bootfs-only
```

## Manual Step

The script pauses and reminds the user to do the one board-side step that
cannot be automated:

1. disconnect the board USB-C cable
2. hold `FDL` (`SW2`)
3. while holding `FDL`, insert the USB-C cable

After that, the script waits for:

- `fastboot devices` to show a ready fastboot device, for example
  `dfu-device fastboot`

For manual interactive serial access during flashing, use `picocom`, for example:

```bash
sudo picocom -b 115200 /dev/ttyUSB1
```

## What Gets Flashed

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

## Bootfs-only Recovery

If the board already has a flashed eMMC image and only the boot partition needs
to be corrected, for example after regenerating `initrd.img-*` and rebuilding
`bootfs.ext4`, you can reflash only `bootfs`:

```bash
sudo bash scripts/eaie_flash.sh --bootfs-only
```

If the boot failure was caused by a missing `initrd.img-*` in `bootfs`, use the
dedicated repair helper first:

```bash
sudo bash scripts/repair-bootfs-initrd.sh
sudo bash scripts/eaie_flash.sh --bootfs-only
```

This helper:

- restores the staged `/boot` tree from `bootfs/`
- runs `update-initramfs` inside the staged `rootfs/`
- verifies that `esos.elf` is embedded in the resulting initrd
- rebuilds `bootfs.ext4`
- preserves the existing bootfs filesystem UUID so `/etc/fstab` in the flashed
  rootfs remains valid

## Validated Baseline

On April 14, 2026, the repo completed a full eMMC flash and first boot to a
serial login prompt using:

- `scripts/eaie_flash.sh`
- Google Android platform-tools `fastboot`
- separate UART monitoring through `picocom`

The resulting baseline is intentionally still stock:

- U-Boot product profile: `k1-x_deb1`
- kernel machine model: `spacemit k1-x deb1 board`
- hostname at boot: `host1`
- successful login as `eaie`

The captured first full boot log is:

- [0001-first-full-boot.log](../scripts/image-logs/0001-first-full-boot.log)

This is the baseline to preserve before beginning DT and board-identity
customization.
