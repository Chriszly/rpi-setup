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

# --- Networking helpers ------------------------------------------------

# First LAN IP of this host, or non-zero exit (and empty output) if none.
pi_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null || true)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip" | awk '{print $1}'
}

# Convert an "ip/prefix" to its network address, e.g. "192.168.1.50/24" -> "192.168.1.0/24".
net_base() {
  local cidr="$1" ip="${1%/*}" prefix="${1##*/}" net
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 1 && prefix <= 32 )) || return 1
  net="$(awk -v ip="$ip" -v p="$prefix" 'BEGIN {
    split(ip, a, ".");
    val = a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4];
    step = 2 ^ (32 - p);
    net = val - (int(val) % step);
    printf "%d.%d.%d.%d/%d\n",
      int(net / 16777216) % 256, int(net / 65536) % 256,
      int(net / 256) % 256, net % 256, p;
  }')" || return 1
  printf '%s\n' "$net"
}

# Detect the LAN network + interface from the default route, e.g. "192.168.1.0/24 --interface=eth0".
detect_subnet() {
  local iface ifip cidr
  iface="$(ip route show default 2>/dev/null | awk '
    /^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$iface" ]] || return 1
  ifip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "$ifip" ]] || return 1
  cidr="$(net_base "$ifip")" || return 1
  printf '%s --interface=%s' "$cidr" "$iface"
}

# --- Docker task helpers -----------------------------------------------

# Die with a helpful message if Docker and the Compose plugin are missing.
require_docker() {
  command -v docker >/dev/null 2>&1 || die 'Docker is required. Run first: sudo bash setup.sh docker'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose is required. Run first: sudo bash setup.sh docker'
}

# True if a container with this exact name is currently running.
compose_is_up() {
  local name="$1"
  docker ps -q --filter "name=^${name}\$" >/dev/null 2>&1
}

# Create $dir and $dir/data, with data owned (numerically) by $uid.
ensure_container_dir() {
  local dir="$1" uid="$2"
  install -m 0755 -d "$dir"
  install -m 0755 -d "$dir/data"
  chown "$uid:$uid" "$dir/data"
}

# Start the compose project at $dir/docker-compose.yml, always pulling images.
compose_up() {
  local dir="$1"
  docker compose -f "$dir/docker-compose.yml" up -d --pull always
}

# Grep container logs until a pattern matches (default: 30 tries, 1s apart).
# Prints the last matching line, or the empty string on timeout.
wait_for_log() {
  local name="$1" pattern="$2" tries="${3:-30}" i line=""
  for i in $(seq 1 "$tries"); do
    line="$(docker logs "$name" 2>&1 | grep -i "$pattern" | tail -1)" || true
    [[ -n "$line" ]] && break
    sleep 1
  done
  printf '%s\n' "$line"
}

# Find an unused UID/GID >= 10000 that isn't a system account and hasn't been
# assigned to another rpi-setup service. Returns the first available ID.
find_free_uid() {
  local start=10000 used=""
  install -m 0755 -d /var/lib/rpi-setup/uids
  used="$(cat /var/lib/rpi-setup/uids/* 2>/dev/null || true)"
  while getent passwd "$start" >/dev/null 2>&1 ||
        getent group "$start" >/dev/null 2>&1 ||
        grep -qx "$start" <<<"$used"; do
    start=$((start + 1))
  done
  printf '%s\n' "$start"
}

# Assign (or recall) a stable UID/GID for a named service, persisted under
# /var/lib/rpi-setup/uids/. Re-runs reuse the same ID so container data keeps a
# consistent owner and services never collide.
assign_uid() {
  local name="$1"
  local file="/var/lib/rpi-setup/uids/$name" uid
  if [[ -r "$file" ]] && [[ "$(<"$file")" =~ ^[0-9]+$ ]]; then
    uid="$(<"$file")"
    if ! getent passwd "$uid" >/dev/null 2>&1 &&
       ! getent group "$uid" >/dev/null 2>&1; then
      printf '%s\n' "$uid"
      return
    fi
    warn "Stored UID $uid for $name is now owned by a system account; reassigning."
  fi
  uid="$(find_free_uid)"
  printf '%s\n' "$uid" >"$file"
  printf '%s\n' "$uid"
}
