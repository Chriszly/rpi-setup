#!/usr/bin/env bash
# Shared helpers for rpi-setup.
set -euo pipefail

# Repository root (the directory holding setup.sh, lib/, tasks/ and config/).
RPI_SETUP_ROOT="${RPI_SETUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

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

# Board model string, e.g. "Raspberry Pi 5 Model B Rev 1.0" (empty off a Pi).
# RPI_SETUP_MODEL_FILE lets the unit tests pretend to be a given board.
pi_model() {
  local f="${RPI_SETUP_MODEL_FILE:-/proc/device-tree/model}"
  [[ -r "$f" ]] || return 0
  tr -d '\0' <"$f"
}

# Loose Raspberry Pi detection (also true when an OS image boots on similar arm boards).
is_pi() { [[ "$(pi_model)" == *[Rr]aspberry* ]]; }

# True on the BCM2712 boards: Pi 5, Pi 500 and Compute Module 5.
is_pi5() { [[ "$(pi_model)" =~ Raspberry\ Pi\ (5|500|Compute\ Module\ 5) ]]; }

# The firmware's config.txt: /boot/firmware since Bookworm, /boot before.
boot_config_file() {
  if [[ -f /boot/firmware/config.txt ]]; then
    printf '%s\n' /boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    printf '%s\n' /boot/config.txt
  else
    return 1
  fi
}

# Replace rpi-setup's block at the end of config.txt ($1) with the lines on
# stdin (no lines removes the block). Returns 0 if the file changed.
boot_config_block() {
  local conf="$1" body new
  body="$(cat)"
  if [[ -z "$body" ]] && ! grep -q '^# BEGIN rpi-setup$' "$conf"; then return 1; fi
  new="$(awk '/^# BEGIN rpi-setup$/ {skip = 1} !skip {print} /^# END rpi-setup$/ {skip = 0}' "$conf")"
  if [[ -n "$body" ]]; then
    new+=$'\n# BEGIN rpi-setup\n# Managed by rpi-setup (config/base.env); re-run "setup.sh base" to change.\n[all]\n'
    new+="$body"$'\n# END rpi-setup'
  fi
  printf '%s\n' "$new" | write_if_changed "$conf"
}

# True inside a container (systemd-nspawn, Docker, ...) rather than on real hardware.
in_container() { [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; }

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

# Refresh apt lists now, ignoring the hourly cache. Needed right after adding
# an apt source: lists fetched a minute ago (e.g. by "base") don't know it yet.
apt_update_now() {
  rm -f /var/lib/rpi-setup/apt-updated
  apt_update
}

# Never stop at a dpkg "configuration file modified" prompt: keep the local
# version when one exists, take the package default otherwise.
APT_DPKG_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_install() {
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_DPKG_OPTS[@]}" "$@"
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

# Name of the process listening on TCP $1 (e.g. "nginx", "pihole-FTL"), or
# non-zero exit if nothing listens there.
port_owner() {
  local port="$1" line
  line="$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n1)" || true
  [[ -n "$line" ]] || return 1
  if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf 'unknown\n'
  fi
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

# Interface of the default route, e.g. "eth0" or "wlan0".
default_iface() {
  local iface
  iface="$(ip route show default 2>/dev/null | awk '
    /^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$iface" ]] || return 1
  printf '%s\n' "$iface"
}

# Detect the LAN network + interface from the default route, e.g. "192.168.1.0/24 --interface=eth0".
detect_subnet() {
  local iface ifip cidr
  iface="$(default_iface)" || return 1
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
  # 'docker ps' exits 0 even when nothing matches, so test the output, not the status.
  [[ -n "$(docker ps -q --filter "name=^${name}\$" --filter status=running 2>/dev/null)" ]]
}

# Create $dir and $dir/data, with data owned (numerically) by $uid.
ensure_container_dir() {
  local dir="$1" uid="$2"
  install -m 0755 -d "$dir"
  install -m 0755 -d "$dir/data"
  chown "$uid:$uid" "$dir/data"
}

# Start the compose project at $dir/docker-compose.yml, always pulling images.
# Dies if no service is running afterwards: 'up -d' can print a daemon error
# for a container that failed to start and still exit 0.
compose_up() {
  local dir="$1" file="$1/docker-compose.yml"
  docker compose -f "$file" up -d --pull always
  [[ -n "$(docker compose -f "$file" ps -q --status running 2>/dev/null)" ]] ||
    die "No container from $file is running. Inspect with: docker compose -f $file logs"
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

# --- Task settings ------------------------------------------------------
#
# config/rpi-setup.env.example  every setting with its default (committed)
# config/rpi-setup.env          your copy with your values (git-ignored)
# config/tasks/<task>.env       names of the settings each task reads (committed)
# config/local/<task>.env       split_config's output, read by setup.sh (git-ignored)

# Folder holding rpi-setup.env and local/. RPI_SETUP_CONFIG_DIR points
# elsewhere, e.g. at a folder kept outside the git checkout.
config_dir() { printf '%s\n' "${RPI_SETUP_CONFIG_DIR:-$RPI_SETUP_ROOT/config}"; }

# The central settings file.
central_config() { printf '%s/rpi-setup.env\n' "$(config_dir)"; }

# The value part of a KEY=value line: surrounding whitespace, a matching pair
# of quotes and a trailing " # comment" are removed. Nothing is expanded, so
# $, backticks and backslashes reach the task literally. Quote a value that
# contains " #"; a value with a double quote in it goes in single quotes.
config_value() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  if [[ "$v" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] || [[ "$v" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  v="${v%%[[:space:]]#*}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Quote $1 so config_value reads it back unchanged.
config_quote() {
  local v="$1"
  if [[ "$v" != *\'* ]]; then
    printf "'%s'" "$v"
  elif [[ "$v" != *\"* ]]; then
    printf '"%s"' "$v"
  else
    die "A setting value cannot contain both ' and \" (a password?); pick another."
  fi
}

# Call "$2 LINE_NO KEY VALUE" for every KEY=value line of file $1; comments
# and blank lines are skipped. A malformed line dies naming its number only,
# since the line itself may hold a password.
config_each() {
  local file="$1" fn="$2" line n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "$file, line $n: expected KEY=value"
    "$fn" "$n" "${BASH_REMATCH[2]}" "$(config_value "${BASH_REMATCH[3]}")"
  done <"$file"
}

# Warn if file $1 holds a non-empty password/key and other users can read it.
config_warn_perms() {
  local file="$1" mode
  mode="$(stat -c %a "$file" 2>/dev/null)" || return 0
  [[ "$mode" =~ ^[0-7]+$ ]] && (( 8#$mode & 077 )) || return 0
  if grep -Eq '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(PASSWORD|AUTHKEY)=[[:space:]]*[^[:space:]#]' "$file"; then
    warn "$file holds a password but other users can read it; run: chmod 600 $file"
  fi
}

# The setting names task $1 reads, from config/tasks/<task>.env, one per line.
task_setting_names() {
  local file="$RPI_SETUP_ROOT/config/tasks/$1.env"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$file"
}

# Read task $1's settings from $2 (default: config/local/<task>.env) into
# shell variables. Only keys named <TASK>_... are accepted, so a settings file
# can never change PATH or another task's settings. A variable that is already
# set (e.g. "sudo SAMBA_PASSWORD=... bash setup.sh samba") wins over the file.
# A missing file is fine: every setting has a default.
load_task_config() {
  local task="$1" file="${2:-}"
  [[ -n "$file" ]] || file="$(config_dir)/local/$task.env"
  [[ -f "$file" ]] || return 0
  [[ -r "$file" ]] || die "Cannot read $file"
  config_warn_perms "$file"
  info "Loading settings from $file"
  _LOAD_TASK="$task" _LOAD_FILE="$file"
  config_each "$file" _load_setting
}
_load_setting() {
  local n="$1" key="$2" value="$3" prefix="${_LOAD_TASK^^}_"
  [[ "$key" == "$prefix"* ]] ||
    die "$_LOAD_FILE, line $n: '$key' is not a setting of the $_LOAD_TASK task (they all start with $prefix)"
  [[ -n "${!key+x}" ]] && return 0
  printf -v "$key" '%s' "$value"
}

# Split the central file $1 (default: config/rpi-setup.env) into one file per
# task under config/local/, each listing every name from config/tasks/<task>.env
# with its value (empty = the task's default). An unknown name in the central
# file stops the split, so a typo never goes unnoticed. The output is private
# (0600) and owned by the invoking user.
split_config() {
  local central="${1:-}"
  [[ -n "$central" ]] || central="$(central_config)"
  local out tpl task key u
  [[ -f "$central" ]] || die "$central not found. Create it with: bash setup.sh --init-config"
  config_warn_perms "$central"
  out="$(config_dir)/local"
  declare -gA _SPLIT_VALUES=() _SPLIT_KNOWN=()
  _SPLIT_FILE="$central"
  for tpl in "$RPI_SETUP_ROOT"/config/tasks/*.env; do
    [[ -f "$tpl" ]] || continue
    while IFS= read -r key; do _SPLIT_KNOWN[$key]=1; done < <(task_setting_names "$(basename "$tpl" .env)")
  done
  config_each "$central" _split_setting

  u="$(real_user)"
  install -m 0700 -d "$out"
  for tpl in "$RPI_SETUP_ROOT"/config/tasks/*.env; do
    [[ -f "$tpl" ]] || continue
    task="$(basename "$tpl" .env)"
    {
      printf '# Generated from %s by split_config - edit that file instead.\n' "$central"
      while IFS= read -r key; do
        printf '%s=%s\n' "$key" "$(config_quote "${_SPLIT_VALUES[$key]:-}")"
      done < <(task_setting_names "$task")
    } | write_if_changed "$out/$task.env" 0600 || true
  done
  if [[ $EUID -eq 0 && "$u" != root ]] && id "$u" >/dev/null 2>&1; then
    chown -R "$u:$(id -gn "$u")" "$out"
  fi
  say "Split $central into $out/<task>.env"
}
_split_setting() {
  local n="$1" key="$2" value="$3"
  [[ -n "${_SPLIT_KNOWN[$key]+x}" ]] ||
    die "$_SPLIT_FILE, line $n: unknown setting '$key' (see config/rpi-setup.env.example for the names)"
  config_quote "$value" >/dev/null
  _SPLIT_VALUES[$key]="$value"
}

# Create config/rpi-setup.env from the example unless it already exists:
# private (0600) and owned by the invoking user, since passwords go in it.
init_config() {
  local dst u
  dst="$(central_config)"
  u="$(real_user)"
  if [[ -e "$dst" ]]; then
    info "Keeping existing $dst"
  else
    install -m 0755 -d "$(dirname "$dst")"
    install -m 0600 "$RPI_SETUP_ROOT/config/rpi-setup.env.example" "$dst"
    if [[ $EUID -eq 0 && "$u" != root ]] && id "$u" >/dev/null 2>&1; then
      chown "$u:$(id -gn "$u")" "$dst"
    fi
    say "Created $dst"
  fi
  say "Fill in $dst, then run: sudo bash setup.sh <task ...>"
}

# True for yes/true/on/1, false for no/false/off/0 (any case). Dies naming the
# setting on anything else, so a typo never silently picks a behaviour.
setting_on() {
  local name="$1" v="${!1:-}"
  case "${v,,}" in
    yes|true|on|1) return 0 ;;
    no|false|off|0) return 1 ;;
    *) die "$name must be yes or no (got '$v')" ;;
  esac
}

# Dies unless setting $1 holds a TCP/UDP port number (1-65535).
require_port() {
  local name="$1" v="${!1:-}"
  if [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then return 0; fi
  die "$name must be a port number between 1 and 65535 (got '$v')"
}

# RFC 1123 host name label: letters, digits and inner '-', at most 63 characters.
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

# Dies unless setting $1 looks like a Docker image reference (name[:tag]).
require_image_ref() {
  local name="$1" v="${!1:-}"
  [[ "$v" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ ]] ||
    die "$name must be a Docker image such as repo/name:tag (got '$v')"
}

# A random alphanumeric password, $1 characters long (default 20).
gen_secret() {
  local n="${1:-20}" s=""
  while (( ${#s} < n )); do
    s+="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s\n' "${s:0:n}"
}

# Record a generated secret in /var/lib/rpi-setup/secrets/<task>.env (root
# only, 0600) so it can be looked up after the console output is gone.
save_secret() {
  local task="$1" key="$2" value="$3" dir=/var/lib/rpi-setup/secrets file
  file="$dir/$task.env"
  install -m 0700 -d "$dir"
  touch "$file"
  chmod 0600 "$file"
  { grep -v "^${key}=" "$file" || true; printf '%s=%s\n' "$key" "$value"; } >"$file.new"
  chmod 0600 "$file.new"
  mv -f "$file.new" "$file"
}

# Write stdin to $1 (mode $2, default 0644) only if the content differs.
# Returns 0 if the file was written, 1 if it already had this content, so a
# task can restart a service only when its configuration really changed.
write_if_changed() {
  local dest="$1" mode="${2:-}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    [[ -z "$mode" ]] || chmod "$mode" "$dest"
    return 1
  fi
  if [[ -f "$dest" && -z "$mode" ]]; then
    cat "$tmp" >"$dest"
  else
    install -m "${mode:-0644}" "$tmp" "$dest"
  fi
  rm -f "$tmp"
  return 0
}

# Set "key = value" in [section] of an INI-style file (netdata.conf,
# smb.conf): an existing uncommented key in that section is replaced, else
# the key is added below the section header, else the section is appended.
# Returns 0 if the file changed.
ini_set() {
  local file="$1" section="$2" key="$3" value="$4"
  [[ -f "$file" ]] || touch "$file"
  awk -v sec="$section" -v key="$key" -v val="$value" '
    function flush() { if (insec && !done) { print "\t" key " = " val; done = 1 } }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      flush()
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      insec = (name == sec)
      if (insec) seen = 1
      print; next
    }
    insec && !done {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (index(line, key) == 1) {
        rest = substr(line, length(key) + 1)
        if (rest ~ /^[[:space:]]*=/) { print "\t" key " = " val; done = 1; next }
      }
    }
    { print }
    END {
      flush()
      if (!seen) { print "[" sec "]"; print "\t" key " = " val }
    }' "$file" | write_if_changed "$file"
}
