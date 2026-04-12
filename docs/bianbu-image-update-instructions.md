# Bianbu Image Update Instructions

## Goal

Update the current Bianbu Ubuntu/LXQt image flow so future images:

- boot with English (`en_US.UTF-8`) as the default language
- include `xterm`
- include `net-tools`
- include the Qt6 Wayland runtime needed by the SDDM greeter and first-boot GUI
- do not ship with a broken `dpkg`/`apt` state

This document is based on the current workspace state and the image that was
already built and booted on the BPI-F3.

## What We Observed

### Current image defaults to Chinese

The current rootfs is built with:

- `LANG=zh_CN.UTF-8` in `/etc/default/locale`
- `LANG=zh_CN.UTF-8` in `/etc/locale.conf`

### The image already uses Ubuntu-style package management

The board already contains:

- `apt`
- `dpkg`
- `iproute2`

So the standard package manager for this image is `apt`.

### The broken package state originates during the container build

The current rootfs logs show the failure happened while installing
`bianbu-desktop-lite` inside the container, not after booting the board.

Observed failures in `rootfs/var/log/apt/term.log`:

- `modemmanager`: `dpkg-deb --control subprocess was killed by signal (Segmentation fault)`
- `fonts-lohit-taml-classical`: `dpkg-deb --fsys-tarfile subprocess was killed by signal (Illegal instruction)`
- `speech-dispatcher`: `pre-installation script subprocess returned error exit status 139`

This strongly suggests a qemu/chroot issue during the riscv64 package install
phase, not a generic Bianbu repository problem.

### The GUI also needs `qt6-wayland`

The booted image reached `sddm`, but the greeter crashed immediately with:

- `Could not find the Qt platform plugin "wayland"`

On the live board, reinstalling `qt6-wayland` fixed the display manager and the
full Bianbu desktop appeared normally.

In the built rootfs, the Qt6 platforms directory did not contain
`libqwayland*.so`, which matches the runtime failure.

## Recommended Update Strategy

Use a two-stage process:

1. Keep the existing container-based rootfs and image generation flow.
2. Add explicit locale and package customization in the rootfs stage.
3. Add a package-state validation step before generating `bootfs.ext4` and
   `rootfs.ext4`.
4. If the container still hits the same qemu package failures, treat that as a
   known builder limitation and complete package repair natively on the board
   before considering the image recipe final.

This means:

- English locale and extra packages are straightforward.
- A fully clean package state may or may not be achievable in the container
  alone with the current qemu-based riscv64 setup.

## Updated Build Instructions

### 1. Build the base rootfs as before

Follow the existing Bianbu 3.0 rootfs flow until the target rootfs is created
and the standard Bianbu packages are installed.

Keep using the same container workflow for now.

### 2. Apply package and locale customizations inside the rootfs stage

Before generating `bootfs.ext4` and `rootfs.ext4`, run the following steps
inside the same chroot/container environment that owns `$TARGET_ROOTFS`.

Use noninteractive apt behavior:

```bash
export DEBIAN_FRONTEND=noninteractive
```

Install locale support and the extra packages we want baked into the image:

```bash
apt-get update
apt-get install -y --allow-downgrades \
    locales \
    language-pack-en \
    qt6-wayland \
    xterm \
    net-tools
```

Generate and set the default locale to US English:

```bash
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
```

Also make sure the persisted locale files are aligned:

```bash
printf 'LANG=en_US.UTF-8\n' > /etc/default/locale
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
```

### 3. Attempt to fully clean the package state in the container

After all package installation steps are done, run:

```bash
dpkg --configure -a
apt-get -f install -y
apt-get clean
```

Then validate that nothing remains unpacked or half-installed:

```bash
dpkg -l | awk '$1 !~ /^(ii|rc)$/ {print}'
```

Expected result:

- no output, or at least no remaining packages in `unpacked`, `half-installed`,
  or `half-configured` states

Also validate that the Qt6 Wayland platform plugin is present in the rootfs:

```bash
ls /usr/lib/riscv64-linux-gnu/qt6/plugins/platforms/libqwayland*.so
```

Expected result:

- one or more `libqwayland*.so` files are present

### 4. Only generate the image after package-state validation

Do not package `bootfs.ext4`, `rootfs.ext4`, SD images, or Titan images until
the validation step above is clean.

If the package database is clean:

- generate `bootfs.ext4`
- generate `rootfs.ext4`
- generate the SD image
- optionally generate the Titan/eMMC package

## Known Builder Limitation

If the container still fails with the same qemu-side package errors for:

- `modemmanager`
- `fonts-lohit-taml-classical`
- `speech-dispatcher`

then container-only finalization is not yet reliable with the current builder.

In that case, use this fallback:

### Native fallback on the board

Boot the provisional image on the BPI-F3 and run:

```bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

dpkg --configure -a
apt update
apt --fix-broken install
apt install -y xterm net-tools language-pack-en qt6-wayland
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
reboot
```

After reboot, verify:

```bash
locale
dpkg -l | awk '$1 !~ /^(ii|rc)$/ {print}'
which xterm
which ifconfig
ls /usr/lib/riscv64-linux-gnu/qt6/plugins/platforms/libqwayland*.so
```

Expected result:

- locale shows `en_US.UTF-8`
- no broken package states remain
- `xterm` exists
- `ifconfig` exists
- the Qt6 Wayland platform plugin exists

## Practical Recommendation For The Next Iteration

For the next image iteration, use this order:

1. Re-run the container rootfs build.
2. Add `language-pack-en`, `qt6-wayland`, `xterm`, and `net-tools` before image packaging.
3. Switch the rootfs locale files to `en_US.UTF-8`.
4. Run `dpkg --configure -a` and `apt-get -f install -y` in the container.
5. Explicitly verify that `libqwayland*.so` exists in the Qt6 platforms
   directory before packaging the image.
6. If the container still fails on the same riscv64/qemu package paths, stop
   treating the container output as final and perform one native repair pass on
   the board.
7. Only after the package state is clean should that recipe be considered the
   new baseline.

## Open Issue

The unresolved part is not the locale change or the extra packages. Those are
easy. The unresolved part is producing a completely clean desktop image in the
container without hitting qemu-related riscv64 package install failures.

That issue should be investigated separately if a strict container-only build is
required.
