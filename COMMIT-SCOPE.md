# GSP projet commit types & scopes

A detailed list of git commit types & scopes used in the EAIE project. Will be increased & centralized as the project evolves.

## Commit Scopes

### Linux image build system, kernel and u-boot
- build-system
- kernel
- uboot

### AI Applications
- ai-apps

### NTN module operations & modem control
- ntn

### Gateway operations (daemons, system configrations, rootfs changes, etc
- system-config
- daemon-control
- rootfs

### Security-based operations for Zero-Trust (security chip, secure boot, etc.)
- zt-secure-element
- zt-secure-boot

## Commit Types
- feat
- fix
- refactor

## Usage Examples
- `feat(build-system): Adding emmc support for bianbu 3.0 build`
- `refactor(ai-apps): Updating CNN`
- `fix(ntn): Fixing AT command control in UART2`
