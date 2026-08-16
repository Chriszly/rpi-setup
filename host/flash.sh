#!/usr/bin/env bash
# flash.sh - Prepare an SD card for a headless Raspberry Pi (Linux host).
#
#   * downloads the latest Raspberry Pi OS Lite (arm64, 64-bit) image
#   * verifies its SHA-256 checksum
#   * writes it to an SD card with dd
#   * enables SSH and creates a login user (headless first boot)
#
# Requires: root, curl, xz, dd, mount, openssl, partprobe (from parted).
# A cached download is re-verified on every run, so interrupted runs are safe.
#
# Example:
#   sudo ./host/flash.sh                                # interactive
#   sudo ./host/flash.sh -d /dev/sda -u pi -p 'change-me'
#   sudo ./host/flash.sh -i /path/to/raspios.img.xz     # use an image you have
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

BASE_URI="https://downloads.raspberrypi.com/raspios_lite_arm64"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$SCRIPT_DIR/downloads}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/rpi-boot}"

DEV=""
IMAGE=""
USER=""
PASS=""
SKIP_CUSTOMIZE=0
LIST_ONLY=0

usage() {
  echo "Usage: $0 [-d DEVICE] [-i IMAGE] [-u USER] [-p PASS] [-k] [-l]"
  echo
  echo "  -d DEVICE   SD card device node (e.g. /dev/sda). Prompts if omitted."
  echo "  -i IMAGE    locally downloaded .img / .img.xz image (no download)."
  echo "  -u USER     username to create on the Pi (prompted if omitted)."
  echo "  -p PASS     password for that user (prompted if omitted, hidden)."
  echo "  -k          skip SSH/user setup; boot to the on-screen wizard."
  echo "  -l          list candidate disks and exit."
  exit 0
}

while getopts "d:i:u:p:klh" opt; do
  case "$opt" in
    d) DEV="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    k) SKIP_CUSTOMIZE=1 ;;
    l) LIST_ONLY=1 ;;
    *) usage ;;
  esac
done

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
  local b removable
  for sys in /sys/class/block/*; do
    b="${sys##*/}"
    case "$b" in
      loop* | ram* | sr*) continue ;;
    esac
    [[ -e "/sys/class/block/$b/partition" ]] && continue   # partitions, not whole disks
    removable="$(cat "/sys/class/block/$b/removable" 2>/dev/null || echo 0)"
    case "$b" in
      sd[a-z] | mmcblk* | nvme* | vd* | xvd*)
        printf '/dev/%s\t%6s GB\tremovable=%s\n' "$b" "$(disk_size_gb "$b")" "$removable" ;;
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

  if [[ ! -f "$img_path" ]]; then
    info "Downloading $img ($release)"
    curl -fL --progress-bar -o "$img_path" "$BASE_URI/images/$release/$img"
  else
    info "Using cached image: $img_path"
  fi
  if [[ ! -f "$sha_path" ]]; then
    curl -fsSL -o "$sha_path" "$BASE_URI/images/$release/$sha"
  fi

  local expected actual
  expected="$(awk '{print $1}' "$sha_path")"
  say "Verifying SHA-256 of $img"
  actual="$(sha256sum "$img_path" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    die "SHA-256 mismatch for $img_path
  expected: $expected
  actual:   $actual"
  fi
  echo "$img_path"
}

pick_device() {
  local line count=0 sel dev
  info 'Detected candidate disks:'
  while read -r line; do
    count=$((count + 1))
    printf '  %d) %s\n' "$count" "$line"
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
  case "${dev##*/}" in
    *[0-9]) die "$dev looks like a partition, not a whole disk." ;;
  esac
  if mount | grep -q "$dev"; then die "$dev has mounted partitions; unmount them first."; fi
  info "Target: $dev ($(disk_size_gb "${dev##*/}") GB)"
  local conf
  read -r -p "Type 'yes' to DESTROY all data on $dev: " conf
  [[ "$conf" == "yes" ]] || die 'Aborted.'
}

generate_hash() {
  local pass="$1" salt h
  command -v openssl >/dev/null 2>&1 || die 'openssl not found. Install openssl or use -k to skip user setup.'
  salt="$(head -c16 /dev/urandom | tr -dc './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' | head -c16)"
  h="$(printf '%s' "$pass" | openssl passwd -6 -stdin -salt "$salt")"
  echo "$h"
}

ask_credentials() {
  if [[ -z "$USER" ]]; then
    read -rp 'Username to create on the Pi: ' USER
    [[ -n "$USER" ]] || die 'Username required.'
  fi
  [[ "$USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username '$USER'. Use lowercase letters/digits/_/-."
  if [[ -z "$PASS" ]]; then
    read -r -s -p 'Password for the Pi user (hidden): ' PASS; echo
    [[ -n "$PASS" ]] || die 'Password required.'
    local pass2
    read -rs -p 'Repeat password: ' pass2; echo
    [[ "$PASS" == "$pass2" ]] || die 'Passwords do not match.'
  fi
  [[ "$PASS" != *:* ]] || die 'Password must not contain a colon (":").'
  if [[ ${#PASS} -lt 8 ]]; then warn 'Password is shorter than 8 characters - consider a stronger one.'; fi
}

if [[ "$LIST_ONLY" -eq 1 ]]; then list_candidates; exit 0; fi

need_root

if [[ -n "$IMAGE" ]]; then
  [[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"
  say "Using image: $IMAGE"
  img_path="$IMAGE"
else
  release="$(latest_release)"
  img_path="$(fetch_image "$release")"
fi

DEV="$(pick_device)"
confirm_device "$DEV"

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
  ask_credentials
  say 'Enabling SSH and creating the login user for headless first boot'
  mkdir -p "$MOUNT_DIR"
  mountpoint -q "$MOUNT_DIR" || mount -o umask=022 "$PART" "$MOUNT_DIR" 2>/dev/null \
      || mount "$PART" "$MOUNT_DIR" || die "Mounting $PART failed."

  : > "$MOUNT_DIR/ssh"
  printf '%s:%s\n' "$USER" "$(generate_hash "$PASS")" > "$MOUNT_DIR/userconf.txt"
  sync
  umount "$MOUNT_DIR"
  say "Wrote to bootfs: 'ssh' (empty) and 'userconf.txt' (user '$USER')"
  info 'On first boot the Pi creates the account and deletes both files.'
fi

sync
say 'Done. Eject the SD card, insert it into the Pi, and power on.'
if [[ "$SKIP_CUSTOMIZE" -eq 0 ]]; then
  say 'After the Pi boots (1-2 minutes), connect over SSH:'
  echo "    ssh $USER@raspberrypi.local"
  echo 'Then on the Pi:'
  echo '    git clone https://github.com/Chriszly/rpi-setup.git'
  echo '    cd rpi-setup && sudo bash setup.sh'
fi