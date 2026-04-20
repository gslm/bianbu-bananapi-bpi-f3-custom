#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="/etc/default/eaie-firstboot-repair"
STATE_DIR="/var/lib/eaie-firstboot-repair"
MARKER_FILE="${STATE_DIR}/enabled"
LOG_FILE="${STATE_DIR}/repair.log"

DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_TIMEZONE="America/Sao_Paulo"
DEFAULT_USER="eaie"
DEFAULT_PASSWORD="eaie"
REPAIR_PACKAGES=""

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

mkdir -p "$STATE_DIR"
exec >>"$LOG_FILE" 2>&1

echo "=== $(date -Is) starting native first-boot repair ==="

if [[ ! -e "$MARKER_FILE" ]]; then
    echo "Marker file not present; nothing to do."
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update || true
dpkg --configure -a || true
apt-get -f install -y || true

if [[ -n "$REPAIR_PACKAGES" ]]; then
    apt-get install -y --allow-downgrades $REPAIR_PACKAGES
fi

dpkg --configure -a
apt-get -f install -y

printf '%s UTF-8\n' "$DEFAULT_LOCALE" > /etc/locale.gen
locale-gen "$DEFAULT_LOCALE"
update-locale LANG="$DEFAULT_LOCALE" LC_ALL="$DEFAULT_LOCALE"
printf 'LANG=%s\nLC_ALL=%s\n' "$DEFAULT_LOCALE" "$DEFAULT_LOCALE" > /etc/default/locale
printf 'LANG=%s\nLC_ALL=%s\n' "$DEFAULT_LOCALE" "$DEFAULT_LOCALE" > /etc/locale.conf

ln -snf "/usr/share/zoneinfo/$DEFAULT_TIMEZONE" /etc/localtime
printf '%s\n' "$DEFAULT_TIMEZONE" > /etc/timezone
dpkg-reconfigure --frontend=noninteractive tzdata

echo "root:${DEFAULT_PASSWORD}" | chpasswd

if ! id -u "$DEFAULT_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$DEFAULT_USER"
fi
echo "${DEFAULT_USER}:${DEFAULT_PASSWORD}" | chpasswd

for group in adm audio cdrom dialout dip input lpadmin netdev plugdev render sudo tss users video; do
    if getent group "$group" >/dev/null 2>&1; then
        usermod -aG "$group" "$DEFAULT_USER"
    fi
done

chown -R "$DEFAULT_USER:$DEFAULT_USER" "/home/$DEFAULT_USER"

systemctl enable ssh-hostkeys.service || true
systemctl enable ssh.service || true

rm -f "$MARKER_FILE"
touch "${STATE_DIR}/completed"

systemctl disable eaie-firstboot-repair.service || true

echo "=== $(date -Is) native first-boot repair completed; rebooting ==="
sync
systemctl reboot
