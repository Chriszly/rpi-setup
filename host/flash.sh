#!/usr/bin/env bash
# flash.sh - Prepare an SD card for a headless Raspberry Pi (Linux host).
#
#   * downloads the latest Raspberry Pi OS Lite (arm64, 64-bit) image
#   * verifies its SHA-256 checksum
#   * writes it to an SD card with dd
#   * enables SSH and creates a login user (headless first boot)
#   * optionally sets the hostname, Wi-Fi and an SSH public key for first boot
#     (cloud-init files on Trixie images, a one-time firstrun.sh on Bookworm)
#   * optionally creates a new SSH key for the Pi to use with GitHub and prints
#     its public key (the private key goes only onto the card)
#
# The optional settings come from flags, from FLASH_* environment variables or
# from the FLASH_* lines of config/rpi-setup.env (nothing else in it is read).
#
# Requires: root, curl, xz, dd, mount, openssl, partprobe (from parted).
# Downloads land in a .part file first, and a cached image is re-verified on
# every run (and downloaded again if it fails), so interrupted runs are safe.
#
# Example:
#   sudo ./host/flash.sh                                # asks for everything, lists the disks
#   sudo ./host/flash.sh -d /dev/sda -u pi -p 'change-me'
#   sudo ./host/flash.sh -i /path/to/raspios.img.xz     # use an image you have
#   sudo ./host/flash.sh -n homepi -s 'My WiFi' -a ~/.ssh/id_ed25519.pub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

BASE_URI="https://downloads.raspberrypi.com/raspios_lite_arm64"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$SCRIPT_DIR/downloads}"
MOUNT_DIR=/mnt/rpi-boot

DEV=""
IMAGE=""
USER=""
PASS=""
SKIP_CUSTOMIZE=0
LIST_ONLY=0

usage() {
  echo "Usage: $0 [-d DEVICE] [-i IMAGE] [-u USER] [-p PASS] [-k] [-l]"
  echo "       [-n HOSTNAME] [-s WIFI_SSID] [-w WIFI_PASSWORD] [-c COUNTRY] [-a PUBKEY_FILE] [-g yes|no]"
  echo
  echo "  -d DEVICE   SD card device node (e.g. /dev/sda). Prompts if omitted."
  echo "  -i IMAGE    locally downloaded .img / .img.xz image (no download)."
  echo "  -u USER     username to create on the Pi (prompted if omitted)."
  echo "  -p PASS     password for that user (prompted if omitted, hidden)."
  echo "  -k          skip SSH/user setup; boot to the on-screen wizard."
  echo "  -l          list candidate disks and exit."
  echo
  echo "First-boot settings (optional; also FLASH_* variables or config/rpi-setup.env):"
  echo "  -n HOSTNAME       host name, e.g. homepi (reachable as homepi.local)."
  echo "  -s WIFI_SSID      Wi-Fi network to join on first boot."
  echo "  -w WIFI_PASSWORD  its password (prompted, hidden, if omitted)."
  echo "  -c COUNTRY        Wi-Fi country code (regulatory domain). Default: DE"
  echo "  -a PUBKEY_FILE    SSH public key to authorize for the user, e.g. ~/.ssh/id_ed25519.pub"
  echo "  -g yes|no         new SSH key for the Pi to use with GitHub, printed at the end (default: yes)."
  exit 0
}

first_partition() {
  local dev="$1" name="${1##*/}"
  case "$name" in
    mmcblk* | nvme*) echo "${dev}p1" ;;                 # mmcblk0p1, nvme0n1p1
    *) echo "${dev}1" ;;                                # sda1, vda1
  esac
}

disk_size_gb() {
  local sectors block="$1"
  sectors="$(cat "/sys/class/block/$block/size")" 2>/dev/null || return
  awk "BEGIN{printf \"%.1f\", $sectors*512/1024/1024/1024}"
}

list_candidates() {
  local b removable model bus
  for sys in /sys/class/block/*; do
    b="${sys##*/}"
    case "$b" in
      loop* | ram* | sr*) continue ;;
    esac
    [[ -e "/sys/class/block/$b/partition" ]] && continue   # partitions, not whole disks
    removable="$(cat "/sys/class/block/$b/removable" 2>/dev/null || echo 0)"
    model="$(tr -s ' ' 2>/dev/null <"/sys/class/block/$b/device/model" | sed 's/ *$//' || true)"
    case "$(readlink -f "$sys")" in
      */usb*) bus=USB ;;
      */mmc*) bus=SD ;;
      */nvme*) bus=NVMe ;;
      *) bus=other ;;
    esac
    case "$b" in
      sd[a-z] | mmcblk* | nvme* | vd* | xvd*)
        printf '/dev/%s\t%6s GB\t%s\t(%s)\tremovable=%s\n' "$b" "$(disk_size_gb "$b")" "${model:-unknown model}" "$bus" "$removable" ;;
    esac
  done
}

latest_release() {
  local html
  if ! html="$(curl -fsSL "$BASE_URI/images/")"; then
    die "Could not query image archive. Check network connectivity or use -i to specify a local image."
  fi
  local latest
  latest="$(echo "$html" | grep -oE 'raspios_lite_arm64-[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | tail -n1)"
  if [[ -z "$latest" ]]; then
    die "Could not determine latest release from archive listing. Use -i to specify a local image."
  fi
  echo "$latest"
}

# Download URL $1 to $2 through a temporary $2.part that is moved into place
# only when the transfer completed, so an interrupted download never leaves a
# file that looks finished. $3 is curl's progress option (-sS or --progress-bar).
download() {
  local url="$1" dest="$2" progress="${3:--sS}"
  rm -f "$dest.part"
  if ! curl -fL "$progress" -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    die "Download failed: $url. Check network connectivity and run the script again."
  fi
  mv -f "$dest.part" "$dest"
}

# Print the path of the downloaded, verified image on stdout (progress goes
# to stderr, since callers capture stdout).
fetch_image() {
  local release="$1" img sha
  img="$(curl -fsSL "$BASE_URI/images/$release/" | grep -oE 'href="[^"]+\.img\.xz"' | head -n1 | sed 's/href="//; s/"$//')"
  if [[ -z "$img" ]]; then
    die "Could not parse release listing for $release. Use -i to specify a local image."
  fi
  sha="$img.sha256"

  mkdir -p "$DOWNLOAD_DIR"
  local img_path="$DOWNLOAD_DIR/$img"
  local sha_path="$DOWNLOAD_DIR/$sha"
  local url="$BASE_URI/images/$release"

  # The checksum file is tiny: fetch it fresh on every run, so a truncated or
  # stale copy can never fail the check forever.
  download "$url/$sha" "$sha_path" -sS
  local expected actual cached
  expected="$(awk '{print $1; exit}' "$sha_path")"
  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
    rm -f "$sha_path"
    die "$url/$sha is not a SHA-256 checksum file. Run the script again later or use -i."
  fi

  # A cached image that fails the check (e.g. left by an older version of this
  # script after an interrupted download) is deleted and downloaded once more.
  for cached in 1 0; do
    if [[ "$cached" -eq 1 ]]; then
      [[ -f "$img_path" ]] || continue
      info "Using cached image: $img_path" >&2
    else
      info "Downloading $img ($release)" >&2
      download "$url/$img" "$img_path" --progress-bar
    fi
    say "Verifying SHA-256 of $img" >&2
    actual="$(sha256sum "$img_path" | awk '{print $1}')"
    if [[ "${expected,,}" == "$actual" ]]; then
      echo "$img_path"
      return 0
    fi
    rm -f "$img_path"
    if [[ "$cached" -eq 1 ]]; then
      warn "Cached image failed the SHA-256 check (interrupted download?); deleted it, downloading again."
    fi
  done
  rm -f "$sha_path"
  die "SHA-256 mismatch for $img (deleted the download)
  expected: $expected
  actual:   $actual
Run the script again to download it afresh."
}

pick_device() {
  local line count=0 sel dev
  # The menu goes to stderr: stdout is the chosen device.
  info 'Detected candidate disks:' >&2
  while read -r line; do
    count=$((count + 1))
    printf '  %d) %s\n' "$count" "$line" >&2
  done < <(list_candidates)
  if [[ "$count" -eq 0 ]]; then
    warn 'No removable SD/USB disks detected. Is your card reader plugged in?'
  fi
  read -rp 'Select the disk to overwrite (number or /dev/node): ' sel
  if [[ "$sel" =~ ^/dev/ ]]; then
    dev="$sel"
  else
    [[ "$sel" =~ ^[0-9]+$ ]] || die 'Invalid selection.'
    dev="$(list_candidates | sed -n "${sel}p" | cut -f1)"
    [[ -n "$dev" ]] || die 'Invalid selection.'
  fi
  echo "$dev"
}

confirm_device() {
  local dev="$1"
  [[ -b "$dev" ]] || die "Not a block device: $dev"
  # Whole disks such as mmcblk0 or nvme0n1 also end in a digit, so ask sysfs
  # instead of looking at the name: only partitions have a "partition" file.
  local node
  node="$(readlink -f "$dev")"
  if [[ -e "/sys/class/block/${node##*/}/partition" ]]; then
    die "$dev looks like a partition, not a whole disk."
  fi
  if mount | grep -q "$dev"; then die "$dev has mounted partitions; unmount them first."; fi
  info "Target: $dev ($(disk_size_gb "${dev##*/}") GB)"
  local conf
  read -r -p "Type 'yes' to DESTROY all data on $dev: " conf
  [[ "$conf" == "yes" ]] || die 'Aborted.'
}

generate_hash() {
  local pass="$1"
  command -v openssl >/dev/null 2>&1 || die 'openssl not found. Install openssl or use -k to skip user setup.'
  # Let openssl generate the salt: it always produces the full 16 characters.
  printf '%s' "$pass" | openssl passwd -6 -stdin
}

ask_credentials() {
  if [[ -z "$USER" ]]; then
    # '|| true': without a terminal (EOF) say what is missing instead of exiting silently.
    read -rp 'Username to create on the Pi: ' USER || true
    [[ -n "$USER" ]] || die 'Username required (-u).'
  fi
  [[ "$USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username '$USER'. Use lowercase letters/digits/_/-."
  if [[ -z "$PASS" ]]; then
    read -r -s -p 'Password for the Pi user (hidden): ' PASS || true; echo
    [[ -n "$PASS" ]] || die 'Password required (-p).'
    local pass2=""
    read -rs -p 'Repeat password: ' pass2 || true; echo
    [[ "$PASS" == "$pass2" ]] || die 'Passwords do not match.'
  fi
  [[ "$PASS" != *:* ]] || die 'Password must not contain a colon (":").'
  if [[ ${#PASS} -lt 8 ]]; then warn 'Password is shorter than 8 characters - consider a stronger one.'; fi
}

# --- first-boot settings: hostname, Wi-Fi, SSH key ------------------------
# All optional. Values come from the flags, else from the environment, else
# from the FLASH_* lines of config/rpi-setup.env. With none of them set the
# card gets exactly what it got before: 'ssh' and 'userconf.txt'.
FLASH_VARS=(FLASH_HOSTNAME FLASH_WIFI_SSID FLASH_WIFI_PASSWORD FLASH_WIFI_COUNTRY FLASH_SSH_PUBKEY_FILE FLASH_GITHUB_KEY)
FLASH_KEYS=""   # validated public key lines, filled by read_pubkeys
FLASH_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$'
# sshd drop-in that makes sshd also read /etc/ssh/authorized_keys/<user>. Keys
# there do not depend on when the login user is created or renamed (userconf.txt
# does that on first boot, after cloud-init or firstrun.sh ran).
FLASH_SSHD_CONF=/etc/ssh/sshd_config.d/10-rpi-setup-authorized-keys.conf
FLASH_SSHD_LINE='AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys/%u'
# Clears the Wi-Fi rfkill block Raspberry Pi OS Lite keeps until a country is set.
# shellcheck disable=SC2016  # expanded on the Pi, not here
FLASH_RFKILL_UNBLOCK='rfkill unblock wifi; for f in /var/lib/systemd/rfkill/*:wlan; do [ -e "$f" ] && echo 0 >"$f"; done; true'
# The Pi's own GitHub key (FLASH_GITHUB_KEY=yes): created on this PC in a temp
# directory, copied to the boot partition as rpi-setup-github-key (+ .pub) and
# deleted here. On the Pi a one-shot service moves it into the login user's
# ~/.ssh (mode 600, owned by the user) once that user exists, and deletes it
# from the boot partition. Mirrors host/flash.ps1.
FLASH_GH_KEY_FILE=rpi-setup-github-key
FLASH_GH_SCRIPT=/usr/local/sbin/rpi-setup-github-key
FLASH_GH_UNIT=rpi-setup-github-key.service
FLASH_GH_DIR=""      # temp directory holding the new key, removed on exit
FLASH_GH_PUB=""      # the new public key line

# Set every FLASH_* variable that is still unset from file $1 (default:
# config/rpi-setup.env). Only FLASH_* lines are read and nothing is expanded,
# so the file can never run code or change anything else.
load_flash_config() {
  local file="${1:-$(central_config)}" line key value
  [[ -f "$file" ]] || return 0
  config_warn_perms "$file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(FLASH_[A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
    case " ${FLASH_VARS[*]} " in
      *" $key "*) ;;
      *) warn "$file: ignoring unknown setting $key"; continue ;;
    esac
    [[ -n "${!key+x}" ]] && continue          # flags and the environment win
    printf -v "$key" '%s' "$(config_value "$value")"
  done <"$file"
}

# True when any first-boot setting is requested (the country alone is not one).
want_firstboot() {
  [[ -n "${FLASH_HOSTNAME:-}" || -n "${FLASH_WIFI_SSID:-}" || -n "${FLASH_SSH_PUBKEY_FILE:-}" ||
     "${FLASH_GITHUB_KEY:-}" == yes ]]
}

# The key-moving script for login user $1 (a validated user name).
github_key_script() {
  # shellcheck disable=SC2016  # expanded on the Pi, not here
  printf '%s\n' \
    '#!/bin/sh' \
    '# Written by rpi-setup host/flash.sh: moves the GitHub SSH key from the boot' \
    "# partition into the login user's ~/.ssh, then deletes it there." \
    "U='$1'" \
    'BOOT=/boot/firmware' \
    '[ -d "$BOOT" ] || BOOT=/boot' \
    'KEY="$BOOT/rpi-setup-github-key"' \
    '[ -f "$KEY" ] || exit 0' \
    'H="$(getent passwd "$U" | cut -d: -f6)"' \
    '# userconf.txt creates the login user; until it exists, try again next boot.' \
    '[ -n "$H" ] && [ -d "$H" ] || exit 0' \
    'G="$(id -gn "$U")"' \
    'install -d -m 0700 -o "$U" -g "$G" "$H/.ssh"' \
    'install -m 0600 -o "$U" -g "$G" "$KEY" "$H/.ssh/id_ed25519_github"' \
    'install -m 0644 -o "$U" -g "$G" "$KEY.pub" "$H/.ssh/id_ed25519_github.pub"' \
    'if ! grep -qs id_ed25519_github "$H/.ssh/config"; then' \
    '  { echo "Host github.com"; echo "  IdentityFile ~/.ssh/id_ed25519_github"; echo "  IdentitiesOnly yes"; echo "  StrictHostKeyChecking accept-new"; } >>"$H/.ssh/config"' \
    '  chown "$U:$G" "$H/.ssh/config"' \
    '  chmod 0600 "$H/.ssh/config"' \
    'fi' \
    'rm -f "$KEY" "$KEY.pub"' \
    'systemctl disable rpi-setup-github-key.service >/dev/null 2>&1 || true'
}

# The systemd unit that runs the key-moving script.
github_key_unit() {
  printf '%s\n' \
    '[Unit]' \
    'Description=Move the rpi-setup GitHub SSH key from the boot partition to the login user' \
    'After=local-fs.target userconfig.service' \
    'ConditionPathExists=|/boot/firmware/rpi-setup-github-key' \
    'ConditionPathExists=|/boot/rpi-setup-github-key' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$FLASH_GH_SCRIPT" \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target'
}

# Create a new ed25519 key without passphrase (comment $1) in a fresh temp
# directory: FLASH_GH_DIR/id_ed25519_github(.pub). Sets FLASH_GH_PUB.
new_github_key() {
  command -v ssh-keygen >/dev/null 2>&1 ||
    die 'ssh-keygen not found. Install openssh-client, or answer "no" to the GitHub key (-g no).'
  FLASH_GH_DIR="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$FLASH_GH_DIR/id_ed25519_github" </dev/null ||
    die 'ssh-keygen failed to create the GitHub key.'
  FLASH_GH_PUB="$(cat "$FLASH_GH_DIR/id_ed25519_github.pub")"
}

# Remove the temp key directory: the Pi's key is never left on this PC.
remove_github_key() {
  [[ -z "$FLASH_GH_DIR" ]] || rm -rf "$FLASH_GH_DIR"
  FLASH_GH_DIR=""
}

# Print the Pi's new GitHub public key and where to add it.
github_key_notice() {
  echo
  say 'New SSH key for the Pi. Add it to GitHub so the Pi can reach your repositories:'
  echo '    https://github.com/settings/ssh/new   (or as a deploy key of one repository)'
  echo
  echo "    $FLASH_GH_PUB"
  echo
  info 'Only the card has the private key; it was not kept on this PC.'
}

# Read the public key file $1 into FLASH_KEYS. Dies unless every non-comment
# line is one OpenSSH public key and there is at least one.
read_pubkeys() {
  local file="$1" line keys=""
  [[ -f "$file" && -r "$file" ]] || die "SSH public key file not found or not readable: $file"
  if grep -q -- '-----BEGIN' "$file"; then
    die "$file is a private key. Pass the public key instead (the .pub file)."
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ $FLASH_KEY_RE || "${line//$'\t'/ }" == *[[:cntrl:]]* ]]; then
      die "$file does not look like an SSH public key (expected e.g. 'ssh-ed25519 AAAA... you@pc', as in ~/.ssh/id_ed25519.pub)."
    fi
    keys+="$line"$'\n'
  done <"$file"
  [[ -n "$keys" ]] || die "$file contains no SSH public key."
  FLASH_KEYS="$keys"
}

# Check the FLASH_* settings before anything is written. Upper-cases the
# country and reads the key file. Never prints the Wi-Fi password.
validate_flash_options() {
  local h="${FLASH_HOSTNAME:-}" ssid="${FLASH_WIFI_SSID:-}" pass="${FLASH_WIFI_PASSWORD:-}"
  if [[ -n "$h" ]]; then
    [[ ${#h} -le 63 && "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      die "Invalid hostname '$h'. Use 1-63 letters, digits and '-', not starting or ending with '-'."
  fi
  FLASH_WIFI_COUNTRY="${FLASH_WIFI_COUNTRY:-DE}"
  FLASH_WIFI_COUNTRY="${FLASH_WIFI_COUNTRY^^}"
  [[ "$FLASH_WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] ||
    die "Invalid Wi-Fi country '$FLASH_WIFI_COUNTRY'. Use a 2-letter code such as DE, AT, CH, GB or US."
  if [[ -n "$ssid" ]]; then
    # Bytes, not characters: the SSID limit is 32 bytes.
    [[ "$(printf %s "$ssid" | wc -c)" -le 32 ]] || die 'Wi-Fi SSID is longer than 32 bytes.'
    [[ "$ssid" != *[[:cntrl:]]* ]] || die 'Wi-Fi SSID must not contain control characters.'
    if [[ -n "$pass" ]]; then
      [[ "$pass" =~ ^[\ -~]{8,63}$ || "$pass" =~ ^[0-9A-Fa-f]{64}$ ]] ||
        die 'Wi-Fi password must be 8-63 printable ASCII characters (or a 64-digit hex key).'
    fi
  elif [[ -n "$pass" ]]; then
    die 'A Wi-Fi password was given without an SSID. Set the SSID too (-s or FLASH_WIFI_SSID).'
  fi
  FLASH_KEYS=""
  if [[ -n "${FLASH_SSH_PUBKEY_FILE:-}" ]]; then
    read_pubkeys "$FLASH_SSH_PUBKEY_FILE"
  fi
  case "${FLASH_GITHUB_KEY:-}" in
    [yY] | [yY][eE][sS] | true | 1) FLASH_GITHUB_KEY=yes ;;
    '' | [nN] | [nN][oO] | false | 0) FLASH_GITHUB_KEY=no ;;
    *) die "Invalid GitHub key setting '$FLASH_GITHUB_KEY'. Use yes or no." ;;
  esac
}

# Home directory of the user who ran sudo (root's home is not where the keys are).
invoking_home() {
  local home
  home="$(getent passwd "$(real_user)" 2>/dev/null | cut -d: -f6)"
  echo "${home:-$HOME}"
}

# The first SSH public key in the invoking user's ~/.ssh, or nothing.
default_pubkey() {
  local home name
  home="$(invoking_home)"
  for name in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    if [[ -f "$home/.ssh/$name" ]]; then echo "$home/.ssh/$name"; return 0; fi
  done
}

# Ask for each first-boot setting that no flag, environment variable or
# settings file gave. Enter keeps the default in brackets. Without a terminal
# to ask on nothing is asked.
can_prompt() { [[ -t 0 ]]; }

ask_flash_settings() {
  can_prompt || return 0
  local key
  if [[ -z "${FLASH_HOSTNAME:-}" ]]; then
    read -rp 'Hostname for the Pi [raspberrypi]: ' FLASH_HOSTNAME || true
  fi
  if [[ -z "${FLASH_WIFI_SSID:-}" ]]; then
    read -rp 'Wi-Fi network name (empty for a network cable only): ' FLASH_WIFI_SSID || true
  fi
  if [[ -n "${FLASH_WIFI_SSID:-}" && -z "${FLASH_WIFI_COUNTRY:-}" ]]; then
    read -rp 'Wi-Fi country code [DE]: ' FLASH_WIFI_COUNTRY || true
  fi
  if [[ -z "${FLASH_SSH_PUBKEY_FILE:-}" ]]; then
    key="$(default_pubkey)"
    if [[ -n "$key" ]]; then
      read -rp "Your PC's SSH public key, to log in to the Pi without a password ['none' to skip] [$key]: " FLASH_SSH_PUBKEY_FILE || true
      case "${FLASH_SSH_PUBKEY_FILE:-}" in
        '') FLASH_SSH_PUBKEY_FILE="$key" ;;
        none) FLASH_SSH_PUBKEY_FILE='' ;;
      esac
    else
      read -rp "Your PC's SSH public key file, to log in to the Pi without a password (empty to skip): " FLASH_SSH_PUBKEY_FILE || true
    fi
    # shellcheck disable=SC2088  # a typed "~/" is expanded here on purpose
    if [[ "$FLASH_SSH_PUBKEY_FILE" == '~/'* ]]; then
      FLASH_SSH_PUBKEY_FILE="$(invoking_home)/${FLASH_SSH_PUBKEY_FILE#\~/}"
    fi
  fi
  # The Pi's own GitHub key is made without asking; -g no turns it off.
  FLASH_GITHUB_KEY="${FLASH_GITHUB_KEY:-yes}"
}

# Ask for the Wi-Fi password when an SSID is set without one. An empty answer
# (or no terminal to ask on) means an open network.
ask_wifi_password() {
  [[ -n "${FLASH_WIFI_SSID:-}" && -z "${FLASH_WIFI_PASSWORD:-}" ]] || return 0
  if [[ -t 0 ]]; then
    read -r -s -p "Wi-Fi password for '$FLASH_WIFI_SSID' (hidden, empty for an open network): " FLASH_WIFI_PASSWORD; echo
  fi
  if [[ -z "${FLASH_WIFI_PASSWORD:-}" ]]; then
    warn "No Wi-Fi password: '$FLASH_WIFI_SSID' is set up as an open network."
  fi
}

# Quote $1 as a YAML single-quoted scalar, where only ' needs escaping (as '').
yaml_quote() {
  local v="$1"
  printf "'%s'" "${v//\'/\'\'}"
}

# Set the Wi-Fi regulatory domain $2 on the kernel command line in
# $1/cmdline.txt, replacing an earlier one, as Raspberry Pi Imager does.
set_cmdline_regdom() {
  local dir="$1" cc="$2" line
  if [[ ! -f "$dir/cmdline.txt" ]]; then
    warn 'No cmdline.txt on the boot partition; the Wi-Fi country is only set in the network settings.'
    return 0
  fi
  line="$(head -n1 "$dir/cmdline.txt" | tr -d '\r\n')"
  line="$(sed -E 's/[[:space:]]*cfg80211\.ieee80211_regdom=[^[:space:]]*//g' <<<"$line")"
  printf '%s cfg80211.ieee80211_regdom=%s\n' "$line" "$cc" >"$dir/cmdline.txt"
}

# Write cloud-init user-data (and network-config when Wi-Fi is set) into the
# boot partition directory $1 for login user $2. The user itself still comes
# from userconf.txt, so no users: entry is written and the image's default
# user handling stays as it is.
write_cloud_init() {
  local dir="$1" user="$2" key
  {
    echo '#cloud-config'
    echo '# Written by rpi-setup host/flash.sh. The login user comes from userconf.txt'
    echo '# and SSH is enabled by the empty "ssh" file, as without these settings.'
    if [[ -n "${FLASH_HOSTNAME:-}" ]]; then
      echo "hostname: $(yaml_quote "$FLASH_HOSTNAME")"
      echo 'manage_etc_hosts: true'
    fi
    if [[ -n "$FLASH_KEYS" || "${FLASH_GITHUB_KEY:-}" == yes ]]; then
      echo 'write_files:'
    fi
    if [[ -n "$FLASH_KEYS" ]]; then
      echo "  - path: $FLASH_SSHD_CONF"
      echo "    permissions: '0644'"
      echo '    content: |'
      echo "      $FLASH_SSHD_LINE"
      echo "  - path: /etc/ssh/authorized_keys/$user"
      echo "    permissions: '0644'"
      echo '    content: |'
      while IFS= read -r key; do
        [[ -z "$key" ]] || echo "      $key"
      done <<<"$FLASH_KEYS"
    fi
    if [[ "${FLASH_GITHUB_KEY:-}" == yes ]]; then
      # Only the script and its unit: the private key itself stays out of
      # user-data, which remains on the boot partition.
      echo "  - path: $FLASH_GH_SCRIPT"
      echo "    permissions: '0755'"
      echo '    content: |'
      github_key_script "$user" | sed 's/^/      /'
      echo "  - path: /etc/systemd/system/$FLASH_GH_UNIT"
      echo "    permissions: '0644'"
      echo '    content: |'
      github_key_unit | sed 's/^./      &/'
    fi
    if [[ -n "${FLASH_WIFI_SSID:-}" || "${FLASH_GITHUB_KEY:-}" == yes ]]; then
      echo 'runcmd:'
    fi
    if [[ -n "${FLASH_WIFI_SSID:-}" ]]; then
      echo "  - [sh, -c, $(yaml_quote "$FLASH_RFKILL_UNBLOCK")]"
    fi
    if [[ "${FLASH_GITHUB_KEY:-}" == yes ]]; then
      echo '  - [systemctl, daemon-reload]'
      echo "  - [systemctl, enable, $FLASH_GH_UNIT]"
      echo "  - [systemctl, start, --no-block, $FLASH_GH_UNIT]"
    fi
  } >"$dir/user-data"

  [[ -n "${FLASH_WIFI_SSID:-}" ]] || return 0
  {
    echo '# Written by rpi-setup host/flash.sh.'
    echo 'network:'
    echo '  version: 2'
    echo '  renderer: NetworkManager'
    echo '  ethernets:'
    echo '    eth0:'
    echo '      dhcp4: true'
    echo '      optional: true'
    echo '  wifis:'
    echo '    wlan0:'
    echo '      dhcp4: true'
    echo '      optional: true'
    echo "      regulatory-domain: $(yaml_quote "$FLASH_WIFI_COUNTRY")"
    echo '      access-points:'
    if [[ -n "${FLASH_WIFI_PASSWORD:-}" ]]; then
      echo "        $(yaml_quote "$FLASH_WIFI_SSID"):"
      echo "          password: $(yaml_quote "$FLASH_WIFI_PASSWORD")"
    else
      echo "        $(yaml_quote "$FLASH_WIFI_SSID"): {}"
    fi
  } >"$dir/network-config"
}

# Escape $1 for a GLib key file string value (NetworkManager connection files).
keyfile_escape() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v// /\\s}"
}

# $1 as a NetworkManager byte list (97;98;99;), which reads back unchanged
# whatever characters the SSID contains.
ssid_bytes() {
  local b out=""
  for b in $(printf '%s' "$1" | od -An -tu1 -v); do out+="$b;"; done
  printf '%s' "$out"
}

# Write firstrun.sh into the boot partition directory $1 for login user $2 and
# start it from cmdline.txt. This is the route Raspberry Pi Imager takes on
# images without cloud-init (Bookworm): the script runs once on first boot,
# removes itself and its cmdline.txt entry, and the Pi reboots.
write_firstrun() {
  local dir="$1" user="$2" uuid line
  [[ -f "$dir/cmdline.txt" ]] || die 'No cmdline.txt on the boot partition; cannot start firstrun.sh.'
  # shellcheck disable=SC2016,SC2028  # these lines are for the Pi's shell, written as-is
  {
    echo '#!/bin/bash'
    echo '# Written by rpi-setup host/flash.sh: one-time first-boot settings for images'
    echo '# without cloud-init. Started from cmdline.txt; removes itself when done.'
    echo 'set +e'
    echo 'BOOT=/boot/firmware'
    echo '[ -f "$BOOT/cmdline.txt" ] || BOOT=/boot'
    if [[ -n "${FLASH_HOSTNAME:-}" ]]; then
      echo "NEW_HOSTNAME='$FLASH_HOSTNAME'"
      echo 'echo "$NEW_HOSTNAME" >/etc/hostname'
      echo 'if grep -q "^127\.0\.1\.1" /etc/hosts; then'
      echo '  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts'
      echo 'else'
      echo '  printf "127.0.1.1\t%s\n" "$NEW_HOSTNAME" >>/etc/hosts'
      echo 'fi'
    fi
    if [[ -n "$FLASH_KEYS" ]]; then
      echo 'install -d -m 0755 /etc/ssh/sshd_config.d /etc/ssh/authorized_keys'
      echo "echo '$FLASH_SSHD_LINE' >$FLASH_SSHD_CONF"
      echo "cat >/etc/ssh/authorized_keys/$user <<'RPI_SETUP_EOF'"
      printf '%s' "$FLASH_KEYS"
      echo 'RPI_SETUP_EOF'
      echo "chmod 0644 $FLASH_SSHD_CONF /etc/ssh/authorized_keys/$user"
    fi
    if [[ -n "${FLASH_WIFI_SSID:-}" ]]; then
      uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
      echo 'NM=/etc/NetworkManager/system-connections'
      echo 'install -d -m 0700 "$NM"'
      echo "cat >\"\$NM/preconfigured.nmconnection\" <<'RPI_SETUP_EOF'"
      echo '[connection]'
      echo 'id=preconfigured'
      [[ -z "$uuid" ]] || echo "uuid=$uuid"
      echo 'type=wifi'
      echo 'autoconnect=true'
      echo
      echo '[wifi]'
      echo 'mode=infrastructure'
      echo "ssid=$(ssid_bytes "$FLASH_WIFI_SSID")"
      if [[ -n "${FLASH_WIFI_PASSWORD:-}" ]]; then
        echo
        echo '[wifi-security]'
        echo 'key-mgmt=wpa-psk'
        echo "psk=$(keyfile_escape "$FLASH_WIFI_PASSWORD")"
      fi
      echo
      echo '[ipv4]'
      echo 'method=auto'
      echo
      echo '[ipv6]'
      echo 'method=auto'
      echo 'RPI_SETUP_EOF'
      echo 'chmod 0600 "$NM/preconfigured.nmconnection"'
      echo "$FLASH_RFKILL_UNBLOCK"
    fi
    if [[ "${FLASH_GITHUB_KEY:-}" == yes ]]; then
      # Runs on the next boot, after userconf.txt has created the login user.
      echo "cat >$FLASH_GH_SCRIPT <<'RPI_SETUP_EOF'"
      github_key_script "$user"
      echo 'RPI_SETUP_EOF'
      echo "chmod 0755 $FLASH_GH_SCRIPT"
      echo "cat >/etc/systemd/system/$FLASH_GH_UNIT <<'RPI_SETUP_EOF'"
      github_key_unit
      echo 'RPI_SETUP_EOF'
      echo "systemctl enable $FLASH_GH_UNIT"
    fi
    echo 'rm -f "$BOOT/firstrun.sh"'
    echo 'sed -i "s| systemd.run.*||g" "$BOOT/cmdline.txt"'
    echo 'exit 0'
  } >"$dir/firstrun.sh"

  line="$(head -n1 "$dir/cmdline.txt" | tr -d '\r\n')"
  if [[ "$line" != *systemd.run=* ]]; then
    line+=' systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target'
  fi
  printf '%s\n' "$line" >"$dir/cmdline.txt"
}

# Write the requested first-boot settings into the boot partition directory
# $1 for login user $2. Writes nothing when no setting is requested.
write_firstboot_config() {
  local dir="$1" user="$2"
  want_firstboot || return 0
  if [[ -n "${FLASH_WIFI_SSID:-}" ]]; then
    set_cmdline_regdom "$dir" "$FLASH_WIFI_COUNTRY"
  fi
  if [[ "${FLASH_GITHUB_KEY:-}" == yes ]]; then
    cp "$FLASH_GH_DIR/id_ed25519_github" "$dir/$FLASH_GH_KEY_FILE"
    cp "$FLASH_GH_DIR/id_ed25519_github.pub" "$dir/$FLASH_GH_KEY_FILE.pub"
  fi
  # A boot partition seeded for cloud-init (Trixie images).
  if [[ -e "$dir/user-data" || -e "$dir/meta-data" ]]; then
    write_cloud_init "$dir" "$user"
    say "Wrote cloud-init settings to bootfs: 'user-data'${FLASH_WIFI_SSID:+ and 'network-config'}"
  else
    write_firstrun "$dir" "$user"
    say "No cloud-init on this image (e.g. Bookworm): wrote 'firstrun.sh'; the Pi reboots once on first boot."
  fi
  [[ -z "${FLASH_HOSTNAME:-}" ]] || info "Hostname: $FLASH_HOSTNAME"
  [[ -z "${FLASH_WIFI_SSID:-}" ]] || info "Wi-Fi: '$FLASH_WIFI_SSID' (country $FLASH_WIFI_COUNTRY)"
  [[ -z "$FLASH_KEYS" ]] || info "SSH key(s) from $FLASH_SSH_PUBKEY_FILE authorized for '$user'"
  [[ "${FLASH_GITHUB_KEY:-}" != yes ]] || info "New GitHub SSH key: moves to ~/.ssh/id_ed25519_github of '$user' on first boot"
}

# --- main ---------------------------------------------------------------
main() {
  local opt
  while getopts "d:i:u:p:kln:s:w:c:a:g:h" opt; do
    case "$opt" in
      d) DEV="$OPTARG" ;;
      i) IMAGE="$OPTARG" ;;
      u) USER="$OPTARG" ;;
      p) PASS="$OPTARG" ;;
      k) SKIP_CUSTOMIZE=1 ;;
      l) LIST_ONLY=1 ;;
      n) FLASH_HOSTNAME="$OPTARG" ;;
      s) FLASH_WIFI_SSID="$OPTARG" ;;
      w) FLASH_WIFI_PASSWORD="$OPTARG" ;;
      c) FLASH_WIFI_COUNTRY="$OPTARG" ;;
      a) FLASH_SSH_PUBKEY_FILE="$OPTARG" ;;
      g) FLASH_GITHUB_KEY="$OPTARG" ;;
      *) usage ;;
    esac
  done

  if [[ "$LIST_ONLY" -eq 1 ]]; then list_candidates; exit 0; fi

  need_root

  # Check the first-boot settings before the card is touched.
  load_flash_config "$(central_config)"
  if [[ "$SKIP_CUSTOMIZE" -eq 1 ]] && want_firstboot; then
    die '-k (skip customization) cannot be combined with a hostname, Wi-Fi or SSH key setting.'
  fi
  [[ "$SKIP_CUSTOMIZE" -eq 1 ]] || ask_flash_settings
  validate_flash_options
  ask_wifi_password
  # Ask for (and check) the login user before the card is wiped, so a typo
  # cannot leave a freshly written card without 'ssh' and 'userconf.txt'.
  local pass_hash=""
  if [[ "$SKIP_CUSTOMIZE" -eq 0 ]]; then
    ask_credentials
    pass_hash="$(generate_hash "$PASS")"
  fi
  if [[ "${FLASH_GITHUB_KEY:-}" == yes ]]; then
    trap remove_github_key EXIT
    new_github_key "$USER@${FLASH_HOSTNAME:-raspberrypi}"
  fi

  # Pick the card last among the questions, so the slow part (download,
  # write) runs without anyone having to wait at the keyboard.
  if [[ -z "$DEV" ]]; then
    DEV="$(pick_device)"
  fi
  confirm_device "$DEV"

  if [[ -n "$IMAGE" ]]; then
    [[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"
    say "Using image: $IMAGE"
    img_path="$IMAGE"
  else
    release="$(latest_release)"
    img_path="$(fetch_image "$release")"
  fi

  info 'Zeroing the start of the disk so partprobe reliably sees the new table'
  dd if=/dev/zero of="$DEV" bs=1M count=8 status=none || true

  say "Writing $img_path to $DEV (this takes a few minutes)"
  if [[ "$img_path" == *.xz ]]; then
    xz -dc "$img_path" | dd of="$DEV" bs=4M status=progress conv=fsync
  else
    dd if="$img_path" of="$DEV" bs=4M status=progress conv=fsync
  fi
  sync

  info 'Rescanning the partition table'
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DEV" || true
  else
    warn 'partprobe not found. If the next step fails, unplug/replug the card and continue from mount below.'
  fi

  PART="$(first_partition "$DEV")"
  for i in $(seq 1 10); do
    [[ -b "$PART" ]] && break
    sleep 1
  done

  if [[ "$SKIP_CUSTOMIZE" -eq 0 ]]; then
    [[ -b "$PART" ]] || die "Could not detect boot partition $PART. Run: sudo partprobe $DEV"
    say 'Enabling SSH and creating the login user for headless first boot'
    mkdir -p "$MOUNT_DIR"
    mountpoint -q "$MOUNT_DIR" || mount -o umask=022 "$PART" "$MOUNT_DIR" 2>/dev/null \
        || mount "$PART" "$MOUNT_DIR" || die "Mounting $PART failed."

    : > "$MOUNT_DIR/ssh"
    printf '%s:%s\n' "$USER" "$pass_hash" >"$MOUNT_DIR/userconf.txt"
    write_firstboot_config "$MOUNT_DIR" "$USER"
    sync
    umount "$MOUNT_DIR"
    say "Wrote to bootfs: 'ssh' (empty) and 'userconf.txt' (user '$USER')"
    info 'On first boot the Pi creates the account and deletes both files.'
  fi

  sync
  say 'Done. Eject the SD card, insert it into the Pi, and power on.'
  if [[ "$SKIP_CUSTOMIZE" -eq 0 ]]; then
    say 'After the Pi boots (1-2 minutes), connect over SSH:'
    echo "    ssh $USER@${FLASH_HOSTNAME:-raspberrypi}.local"
    echo 'Then on the Pi:'
    echo '    git clone https://github.com/Chriszly/rpi-setup.git'
    echo '    cd rpi-setup && sudo bash setup.sh'
    [[ -z "$FLASH_GH_PUB" ]] || github_key_notice
  fi
}

# Only run when executed directly; ci/test-lib.sh sources this file to test
# the helper functions without touching any disk.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi