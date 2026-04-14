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
- optional serial capture to a logfile
- detection of the board in DFU download mode
- the staged `fastboot` flashing sequence for eMMC

## Usage

Run from the repository root:

```bash
sudo bash scripts/eaie_flash.sh
```

With serial capture:

```bash
sudo bash scripts/eaie_flash.sh --port /dev/ttyUSB0
```

Bootfs-only recovery:

```bash
sudo bash scripts/eaie_flash.sh --bootfs-only
```

The script assumes the serial console runs at `115200` baud unless another rate
is passed with `--baud`.

## Manual Step

The script pauses and reminds the user to do the one board-side step that
cannot be automated:

1. disconnect the board USB-C cable
2. hold `FDL` (`SW2`)
3. while holding `FDL`, insert the USB-C cable

After that, the script waits for:

- `fastboot devices` to show `DFU download`

If serial logging is enabled, the script configures the UART and records the ROM
console to a log file under `.bianbu-build/flash-logs/`.

For manual interactive serial access outside the script, `picocom` still works,
for example:

```bash
sudo picocom -b 115200 /dev/ttyUSB0
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
