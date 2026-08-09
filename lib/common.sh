#!/usr/bin/env bash
# Shared helpers for rpi-setup.
set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_CYAN=$'\033[36m'

say()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
hr()   { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }

# The user who invoked setup (resolves properly through sudo).
real_user() { printf '%s' "${SUDO_USER:-${USER:-root}}"; }

# Loose Raspberry Pi detection (also true when an OS image boots on similar arm boards).
is_pi() { [[ -r /proc/device-tree/model ]] && grep -qi 'raspberry' /proc/device-tree/model; }

need_root() { [[ $EUID -eq 0 ]] || die 'Please run as root: sudo bash setup.sh [task ...]'; }

# Refresh apt lists at most once an hour per run.
apt_update() {
  if [[ ! -f /var/lib/rpi-setup/apt-updated ]] ||
     [[ $(( $(date +%s) - $(stat -c %Y /var/lib/rpi-setup/apt-updated) )) -gt 3600 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    install -m 0755 -d /var/lib/rpi-setup
    touch /var/lib/rpi-setup/apt-updated
  fi
}

apt_install() {
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_installed() { dpkg -s "$1" >/dev/null 2>&1; }