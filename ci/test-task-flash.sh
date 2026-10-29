#!/usr/bin/env bash
# test-task-flash.sh - tests for the first-boot settings of host/flash.sh
# (hostname, Wi-Fi, SSH key). A temporary directory stands in for the SD
# card's boot partition, so no disk is touched.
#
# Run: bash ci/test-task-flash.sh     (sudo for the root-only CLI cases)
# Several cases compare literal $ strings on purpose.
# shellcheck disable=SC2016
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
# Sourcing host/flash.sh loads lib/common.sh and defines the helpers without
# running main().
. "$ROOT/host/flash.sh"

CMDLINE='console=serial0,115200 console=tty1 root=PARTUUID=abcd-02 rootfstype=ext4 fsck.repair=yes rootwait'
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx4Wp1PpH0Qm5b6kG5a0bq0nZ4s2yY1j0mQ3v5fYk8e you@pc'
printf '%s\n' "$KEY" >"$TMP/id_ed25519.pub"

# A fresh fake boot partition: $1 = trixie (cloud-init seed files) or bookworm.
new_bootfs() {
    local d="$TMP/boot-$1-$RANDOM"
    mkdir -p "$d"
    printf '%s\n' "$CMDLINE" >"$d/cmdline.txt"
    if [[ "$1" == trixie ]]; then
        printf '#cloud-config\n# shipped\n' >"$d/user-data"
        printf 'instance-id: rpios-image\n' >"$d/meta-data"
        printf '# shipped network-config\n' >"$d/network-config"
    fi
    printf '%s' "$d"
}

reset_flash_vars() {
    unset FLASH_HOSTNAME FLASH_WIFI_SSID FLASH_WIFI_PASSWORD FLASH_WIFI_COUNTRY FLASH_SSH_PUBKEY_FILE FLASH_GITHUB_KEY
    FLASH_KEYS=""
}

have_yaml=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then have_yaml=1; fi
# yaml_get FILE PYTHON-EXPR  - print the value of EXPR over the parsed document d
yaml_get() {
    python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# --- unset: nothing new is written ---------------------------------------------
reset_flash_vars
validate_flash_options
assert_eq "country defaults to DE" "DE" "$FLASH_WIFI_COUNTRY"
assert_fails "want_firstboot is false with only the default country" want_firstboot
for img in trixie bookworm; do
    d="$(new_bootfs "$img")"
    before="$(cd "$d" && ls -A && cat -- *)"
    write_firstboot_config "$d" pi >/dev/null
    assert_eq "unset settings leave the $img bootfs untouched" "$before" "$(cd "$d" && ls -A && cat -- *)"
done

# --- yaml_quote -------------------------------------------------------------------
assert_eq "yaml_quote wraps plain text" "'abc'" "$(yaml_quote abc)"
assert_eq "yaml_quote doubles single quotes" "'it''s'" "$(yaml_quote "it's")"
assert_eq "yaml_quote keeps colon, # and double quotes" "'a: #b \"c\"'" "$(yaml_quote 'a: #b "c"')"

# --- Trixie (cloud-init): user-data and network-config ---------------------------
reset_flash_vars
FLASH_HOSTNAME=homepi
FLASH_WIFI_SSID=$'Caf\xc3\xa9 it\'s: #1 "net"'
FLASH_WIFI_PASSWORD=$'p\'a"ss: #word\\ x'
FLASH_WIFI_COUNTRY=de
FLASH_SSH_PUBKEY_FILE="$TMP/id_ed25519.pub"
validate_flash_options
assert_eq "country is upper-cased" "DE" "$FLASH_WIFI_COUNTRY"
assert_eq "the key file is read" "$KEY" "${FLASH_KEYS%$'\n'}"
d="$(new_bootfs trixie)"
out="$(write_firstboot_config "$d" alice 2>&1)"
assert_eq "cloud-init image gets no firstrun.sh" "no" "$([[ -e "$d/firstrun.sh" ]] && echo yes || echo no)"
assert_eq "meta-data is left alone" "instance-id: rpios-image" "$(cat "$d/meta-data")"
ud="$(cat "$d/user-data")"
assert_eq "user-data starts with #cloud-config" "#cloud-config" "$(head -n1 "$d/user-data")"
assert_contains "user-data sets the hostname" "hostname: 'homepi'" "$ud"
assert_contains "user-data manages /etc/hosts" "manage_etc_hosts: true" "$ud"
assert_contains "user-data writes the key for the user" "path: /etc/ssh/authorized_keys/alice" "$ud"
assert_contains "user-data carries the key" "      $KEY" "$ud"
assert_contains "user-data points sshd at the key file" "$FLASH_SSHD_LINE" "$ud"
assert_contains "user-data unblocks Wi-Fi" "rfkill unblock wifi" "$ud"
assert_eq "user-data has no users: entry (userconf.txt makes the user)" "" "$(grep -E '^users:' "$d/user-data" || true)"
nc="$(cat "$d/network-config")"
assert_contains "network-config is netplan v2" "version: 2" "$nc"
assert_contains "network-config sets wlan0" "    wlan0:" "$nc"
assert_contains "network-config sets the country" "regulatory-domain: 'DE'" "$nc"
assert_contains "network-config quotes the SSID" "'Caf"$'\xc3\xa9'" it''s: #1 \"net\"':" "$nc"
assert_eq "the Wi-Fi password is never printed" "" "$(grep -F 'ss: #word' <<<"$out" || true)"
assert_contains "cmdline.txt gets the regulatory domain" "$CMDLINE cfg80211.ieee80211_regdom=DE" "$(cat "$d/cmdline.txt")"
assert_eq "cmdline.txt stays one line" "1" "$(wc -l <"$d/cmdline.txt")"
if [[ $have_yaml -eq 1 ]]; then
    assert_eq "user-data parses: hostname" "homepi" "$(yaml_get "$d/user-data" 'd["hostname"]')"
    assert_eq "user-data parses: key file content" "$KEY" "$(yaml_get "$d/user-data" 'd["write_files"][1]["content"].strip()')"
    assert_eq "user-data parses: runcmd" "sh" "$(yaml_get "$d/user-data" 'd["runcmd"][0][0]')"
    assert_eq "network-config parses: SSID round-trips" "$FLASH_WIFI_SSID" \
        "$(yaml_get "$d/network-config" 'list(d["network"]["wifis"]["wlan0"]["access-points"])[0]')"
    assert_eq "network-config parses: password round-trips" "$FLASH_WIFI_PASSWORD" \
        "$(yaml_get "$d/network-config" 'list(d["network"]["wifis"]["wlan0"]["access-points"].values())[0]["password"]')"
    assert_eq "network-config parses: country" "DE" \
        "$(yaml_get "$d/network-config" 'd["network"]["wifis"]["wlan0"]["regulatory-domain"]')"
else
    skip "YAML parse checks (python3 with PyYAML not installed)"
fi

# Re-running on the same card does not stack up cmdline.txt entries.
write_firstboot_config "$d" alice >/dev/null 2>&1
assert_eq "regulatory domain is replaced, not added again" "$CMDLINE cfg80211.ieee80211_regdom=DE" "$(cat "$d/cmdline.txt")"

# Hostname only: user-data, but the shipped network-config and cmdline.txt stay.
reset_flash_vars
FLASH_HOSTNAME=pi5
validate_flash_options
d="$(new_bootfs trixie)"
write_firstboot_config "$d" pi >/dev/null
assert_contains "hostname-only user-data" "hostname: 'pi5'" "$(cat "$d/user-data")"
assert_eq "hostname-only keeps the shipped network-config" "# shipped network-config" "$(cat "$d/network-config")"
assert_eq "hostname-only leaves cmdline.txt alone" "$CMDLINE" "$(cat "$d/cmdline.txt")"
assert_eq "hostname-only writes no runcmd" "" "$(grep runcmd "$d/user-data" || true)"

# Open network: access point without a password.
reset_flash_vars
FLASH_WIFI_SSID=guest
validate_flash_options
d="$(new_bootfs trixie)"
write_firstboot_config "$d" pi >/dev/null
assert_contains "open network has no password" "'guest': {}" "$(cat "$d/network-config")"

# --- Bookworm (no cloud-init): firstrun.sh ----------------------------------------
reset_flash_vars
FLASH_HOSTNAME=homepi
FLASH_WIFI_SSID='my;net #1'
FLASH_WIFI_PASSWORD=' back\slash pw'
FLASH_SSH_PUBKEY_FILE="$TMP/id_ed25519.pub"
validate_flash_options
d="$(new_bootfs bookworm)"
write_firstboot_config "$d" bob >/dev/null
assert_eq "no user-data is written on a Bookworm image" "no" "$([[ -e "$d/user-data" ]] && echo yes || echo no)"
fr="$(cat "$d/firstrun.sh")"
assert_ok "firstrun.sh is valid bash" bash -n "$d/firstrun.sh"
assert_contains "firstrun.sh sets the hostname" "NEW_HOSTNAME='homepi'" "$fr"
assert_contains "firstrun.sh installs the key for the user" "cat >/etc/ssh/authorized_keys/bob <<'RPI_SETUP_EOF'"$'\n'"$KEY"$'\nRPI_SETUP_EOF' "$fr"
assert_contains "firstrun.sh writes the sshd drop-in" "$FLASH_SSHD_LINE" "$fr"
assert_contains "firstrun.sh stores the SSID as bytes" "ssid=109;121;59;110;101;116;32;35;49;" "$fr"
assert_contains "firstrun.sh escapes the psk" 'psk=\sback\\slash\spw' "$fr"
assert_contains "firstrun.sh unblocks Wi-Fi" "rfkill unblock wifi" "$fr"
assert_contains "firstrun.sh removes itself" 'rm -f "$BOOT/firstrun.sh"' "$fr"
assert_eq "cmdline.txt: regdom before the one-time systemd.run" \
    "$CMDLINE cfg80211.ieee80211_regdom=DE systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" \
    "$(cat "$d/cmdline.txt")"
# What firstrun.sh strips from cmdline.txt when it is done leaves the regdom in.
assert_eq "firstrun.sh's cleanup keeps the regdom" "$CMDLINE cfg80211.ieee80211_regdom=DE" \
    "$(sed "s| systemd.run.*||g" "$d/cmdline.txt")"
write_firstboot_config "$d" bob >/dev/null
assert_eq "systemd.run is added only once" "1" "$(grep -o 'systemd.run=' "$d/cmdline.txt" | wc -l)"
assert_eq "ssid_bytes handles UTF-8" "67;97;102;195;169;" "$(ssid_bytes $'Caf\xc3\xa9')"

# --- validation failures ---------------------------------------------------------
bad() { # bad NAME VAR=VALUE...   validate_flash_options must fail
    local name="$1"; shift
    assert_fails "$name" bash -c '. "$1/host/flash.sh"; shift; for a in "$@"; do export "${a?}"; done; validate_flash_options' _ "$ROOT" "$@"
}
bad "hostname starting with -" FLASH_HOSTNAME=-pi
bad "hostname ending with -" FLASH_HOSTNAME=pi-
bad "hostname with _" FLASH_HOSTNAME=my_pi
bad "hostname with a dot" FLASH_HOSTNAME=pi.lan
bad "hostname longer than 63" "FLASH_HOSTNAME=$(printf 'a%.0s' {1..64})"
bad "country with 3 letters" FLASH_WIFI_COUNTRY=DEU
bad "country with a digit" FLASH_WIFI_COUNTRY=D1
bad "SSID longer than 32 bytes" "FLASH_WIFI_SSID=$(printf 'x%.0s' {1..33})"
bad "SSID of 17 characters but 34 bytes" "FLASH_WIFI_SSID=$(printf '\xc3\xa9%.0s' {1..17})"
bad "SSID with a newline" $'FLASH_WIFI_SSID=a\nb'
bad "Wi-Fi password shorter than 8" FLASH_WIFI_SSID=net FLASH_WIFI_PASSWORD=short
bad "Wi-Fi password longer than 63" FLASH_WIFI_SSID=net "FLASH_WIFI_PASSWORD=$(printf 'p%.0s' {1..64})"
bad "Wi-Fi password without SSID" FLASH_WIFI_PASSWORD=longenough
bad "missing key file" "FLASH_SSH_PUBKEY_FILE=$TMP/nope.pub"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn\n-----END OPENSSH PRIVATE KEY-----\n' >"$TMP/id_private"
bad "private key file" "FLASH_SSH_PUBKEY_FILE=$TMP/id_private"
printf 'hello world\n' >"$TMP/junk.pub"
bad "file that is no public key" "FLASH_SSH_PUBKEY_FILE=$TMP/junk.pub"
printf '%s\nnot a key\n' "$KEY" >"$TMP/mixed.pub"
bad "key file with a junk line" "FLASH_SSH_PUBKEY_FILE=$TMP/mixed.pub"
: >"$TMP/empty.pub"
bad "empty key file" "FLASH_SSH_PUBKEY_FILE=$TMP/empty.pub"
reset_flash_vars
FLASH_HOSTNAME=Pi-5 FLASH_WIFI_SSID=net FLASH_WIFI_PASSWORD="$(printf 'a%.0s' {1..64})"
assert_ok "64-digit hex key and a mixed-case hostname are accepted" validate_flash_options
printf '# my keys\n%s\n\necdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= other\n' "$KEY" >"$TMP/two.pub"
read_pubkeys "$TMP/two.pub"
assert_eq "comments and blank lines are skipped, all keys kept" "2" "$(grep -c . <<<"$FLASH_KEYS")"

# --- load_flash_config -------------------------------------------------------------
reset_flash_vars
cat >"$TMP/rpi-setup.env" <<'EOF'
# settings
BASE_HOSTNAME=ignored
FLASH_HOSTNAME=fromfile
FLASH_WIFI_SSID="Home: #1"   # comment
export FLASH_WIFI_PASSWORD='pa$s"word'
FLASH_WIFI_COUNTRY=AT
FLASH_TYPO=1
EOF
chmod 600 "$TMP/rpi-setup.env"
FLASH_WIFI_COUNTRY=CH
out="$(load_flash_config "$TMP/rpi-setup.env" 2>&1)"
load_flash_config "$TMP/rpi-setup.env" >/dev/null 2>&1
assert_eq "config file sets the hostname" "fromfile" "${FLASH_HOSTNAME:-}"
assert_eq "config file values are unquoted, comment dropped" "Home: #1" "${FLASH_WIFI_SSID:-}"
assert_eq "config file values are not expanded" 'pa$s"word' "${FLASH_WIFI_PASSWORD:-}"
assert_eq "a variable already set wins over the file" "CH" "$FLASH_WIFI_COUNTRY"
assert_eq "non-FLASH lines are not read" "" "${BASE_HOSTNAME:-}"
assert_contains "unknown FLASH_ names are reported" "FLASH_TYPO" "$out"
assert_ok "a missing config file is fine" load_flash_config "$TMP/none.env"
reset_flash_vars
FLASH_HOSTNAME=""
load_flash_config "$TMP/rpi-setup.env" >/dev/null 2>&1
assert_eq "an empty variable takes the file's value (empty means default)" "fromfile" "$FLASH_HOSTNAME"
reset_flash_vars
printf 'FLASH_HOSTNAME=first\nFLASH_HOSTNAME=second\n' >"$TMP/dup.env"
out="$(load_flash_config "$TMP/dup.env" 2>&1; printf '%s' "$FLASH_HOSTNAME")"
assert_contains "of a repeated setting the first line wins, with a warning" "set more than once" "$out"
assert_eq "the first value of a repeated setting is kept" "first" "${out##*$'\n'}"
# The example's flash section, uncommented, reads back with its defaults.
reset_flash_vars
sed -n 's/^#\(FLASH_[A-Z_]*=\)/\1/p' "$ROOT/config/rpi-setup.env.example" >"$TMP/example.env"
assert_eq "the example lists all six FLASH_* names" "6" "$(grep -c . "$TMP/example.env")"
load_flash_config "$TMP/example.env"
assert_eq "the example's country default is DE" "DE" "${FLASH_WIFI_COUNTRY:-}"
assert_fails "the example's defaults request nothing" want_firstboot
# setup.sh on the Pi splits the same file: FLASH_* lines must not stop it.
mkdir -p "$TMP/cfg"
printf 'FLASH_HOSTNAME=homepi\nFLASH_WIFI_SSID=net\n' >"$TMP/cfg/rpi-setup.env"
chmod 600 "$TMP/cfg/rpi-setup.env"
assert_ok "setup.sh's split_config accepts FLASH_* names" \
    env RPI_SETUP_CONFIG_DIR="$TMP/cfg" bash -c '. "$1/lib/common.sh"; split_config' _ "$ROOT"

# --- fetch_image: download, cache and checksum ---------------------------------------
# A file:// mirror stands in for downloads.raspberrypi.com; curl is wrapped
# only to serve the release directory listing, which file:// cannot.
REL=raspios_lite_arm64-2099-01-01
IMG=2099-01-01-raspios-lite-arm64.img.xz
MIRROR="$TMP/mirror/images/$REL"
mkdir -p "$MIRROR"
printf 'image bytes\n' >"$MIRROR/$IMG"
printf '%s  %s\n' "$(sha256sum "$MIRROR/$IMG" | awk '{print $1}')" "$IMG" >"$MIRROR/$IMG.sha256"
curl() {
    if [[ "${*: -1}" == */ ]]; then printf '<a href="%s">%s</a>\n' "$IMG" "$IMG"; return 0; fi
    command curl "$@"
}
fetch() { # fetch DIR  - run fetch_image with DOWNLOAD_DIR=DIR; stdout only
    (DOWNLOAD_DIR="$1" BASE_URI="file://$TMP/mirror"; fetch_image "$REL") 2>"$TMP/fetch.err"
}
dl="$TMP/dl1"
assert_eq "fetch_image prints only the image path" "$dl/$IMG" "$(fetch "$dl")"
assert_eq "fetch_image downloads the image" "image bytes" "$(cat "$dl/$IMG")"
assert_eq "no .part files are left behind" "" "$(find "$dl" -maxdepth 1 -name '*.part')"
# Truncated image and checksum left by an interrupted run: replaced, not fatal.
printf 'ima' >"$dl/$IMG"
printf 'abc' >"$dl/$IMG.sha256"
assert_eq "a truncated cached image is downloaded again" "$dl/$IMG" "$(fetch "$dl")"
assert_contains "the re-download is explained" "failed the SHA-256 check" "$(cat "$TMP/fetch.err")"
assert_eq "the image is complete after the re-download" "image bytes" "$(cat "$dl/$IMG")"
assert_eq "the checksum file is fetched fresh" "$(cat "$MIRROR/$IMG.sha256")" "$(cat "$dl/$IMG.sha256")"
assert_eq "a good cached image is reused" "$dl/$IMG" "$(fetch "$dl")"
assert_contains "the cached image is reported" "Using cached image" "$(cat "$TMP/fetch.err")"
# A download that does not match the checksum is deleted, so the next run starts over.
printf 'corrupt\n' >"$MIRROR/$IMG"
dl="$TMP/dl2"
assert_fails "a checksum mismatch stops" fetch "$dl"
assert_contains "the mismatch says to run again" "Run the script again" "$(cat "$TMP/fetch.err")"
assert_eq "the mismatching image and checksum are deleted" "" "$(ls -A "$dl")"
rm "$MIRROR/$IMG"
assert_fails "a failed download stops" fetch "$dl"
assert_eq "a failed download leaves no partial file" "$IMG.sha256" "$(ls -A "$dl")"
curl() { if [[ "${*: -1}" == */ ]]; then return 22; fi; command curl "$@"; }
assert_fails "an unreachable release listing stops" fetch "$dl"
assert_contains "an unreachable release listing is explained" "Could not fetch the release listing" "$(cat "$TMP/fetch.err")"
unset -f curl fetch

# --- ask_flash_settings: asks only for what was not given ---------------------------
saved_helpers="$(declare -f can_prompt default_pubkey invoking_home)"
can_prompt() { return 0; }
default_pubkey() { echo /home/alice/.ssh/id_ed25519.pub; }
invoking_home() { echo /home/alice; }
reset_flash_vars
ask_flash_settings <<<$'homepi\n\n\n' >/dev/null 2>&1   # hostname, no Wi-Fi, default key
assert_eq "ask_flash_settings takes the typed hostname" "homepi" "$FLASH_HOSTNAME"
assert_eq "ask_flash_settings: empty Wi-Fi name means cable only" "" "$FLASH_WIFI_SSID"
assert_eq "ask_flash_settings: no country asked without Wi-Fi" "" "${FLASH_WIFI_COUNTRY:-}"
assert_eq "ask_flash_settings: Enter takes the key found in ~/.ssh" "/home/alice/.ssh/id_ed25519.pub" "$FLASH_SSH_PUBKEY_FILE"
assert_eq "ask_flash_settings creates a GitHub key without asking" "yes" "$FLASH_GITHUB_KEY"
reset_flash_vars
FLASH_HOSTNAME=given
FLASH_GITHUB_KEY=no
ask_flash_settings <<<$'My WiFi\nat\nnone\n' >/dev/null 2>&1   # no hostname question: it was given
assert_eq "ask_flash_settings does not ask for a value that was given" "given" "$FLASH_HOSTNAME"
assert_eq "ask_flash_settings asks for the Wi-Fi name" "My WiFi" "$FLASH_WIFI_SSID"
assert_eq "ask_flash_settings asks for the country after a Wi-Fi name" "at" "$FLASH_WIFI_COUNTRY"
assert_eq "ask_flash_settings: 'none' means password login only" "" "$FLASH_SSH_PUBKEY_FILE"
assert_eq "ask_flash_settings keeps -g no" "no" "$FLASH_GITHUB_KEY"
reset_flash_vars
ask_flash_settings <<<$'\n\n~/keys/pi.pub\n' >/dev/null 2>&1
assert_eq "ask_flash_settings expands a typed ~/ to the invoking user's home" "/home/alice/keys/pi.pub" "$FLASH_SSH_PUBKEY_FILE"
# A typed Wi-Fi password is checked like a setting; without a terminal the
# network is open.
reset_flash_vars
FLASH_WIFI_SSID=net
assert_fails "ask_wifi_password refuses a typed password shorter than 8" eval 'ask_wifi_password <<<"short"'
assert_ok "ask_wifi_password takes a typed 8-63 character password" eval 'ask_wifi_password <<<"long enough"'
can_prompt() { return 1; }
out="$(ask_wifi_password 2>&1)"
assert_contains "ask_wifi_password without a terminal means an open network" "open network" "$out"
can_prompt() { return 0; }
# A ~/ from the settings file or the environment is expanded too, not only a typed one.
reset_flash_vars
invoking_home() { echo "$TMP/home"; }
mkdir -p "$TMP/home/keys"; cp "$TMP/id_ed25519.pub" "$TMP/home/keys/pi.pub"
FLASH_SSH_PUBKEY_FILE='~/keys/pi.pub'
validate_flash_options
assert_eq "validate_flash_options expands ~/ in FLASH_SSH_PUBKEY_FILE" "$TMP/home/keys/pi.pub" "$FLASH_SSH_PUBKEY_FILE"
assert_eq "the key behind ~/ is read" "$KEY" "${FLASH_KEYS%$'\n'}"
reset_flash_vars
eval "$saved_helpers"   # restore the real helpers

# --- GitHub key: created in a temp directory, copied to the card, kept out of user-data
reset_flash_vars
FLASH_GITHUB_KEY=Y
validate_flash_options
assert_eq "a yes-like GitHub key setting becomes yes" "yes" "$FLASH_GITHUB_KEY"
assert_ok "want_firstboot is true with only the GitHub key" want_firstboot
FLASH_GITHUB_KEY=maybe
assert_fails "an invalid GitHub key setting is refused" validate_flash_options
FLASH_GITHUB_KEY=true
normalize_github_key
assert_eq "normalize_github_key turns true into yes before the -k check" "yes" "$FLASH_GITHUB_KEY"
assert_ok "want_firstboot sees the normalised value" want_firstboot
FLASH_GITHUB_KEY=""
normalize_github_key
assert_eq "normalize_github_key leaves an empty setting empty" "" "$FLASH_GITHUB_KEY"
FLASH_GITHUB_KEY=yes
if command -v ssh-keygen >/dev/null 2>&1; then
    new_github_key pi@homepi
    gh_dir="$FLASH_GH_DIR"
    assert_contains "new_github_key creates an ed25519 key with the comment" "pi@homepi" "$FLASH_GH_PUB"
    assert_eq "new_github_key's key starts with ssh-ed25519" "ssh-ed25519" "${FLASH_GH_PUB%% *}"
    for img in trixie bookworm; do
        d="$(new_bootfs "$img")"
        write_firstboot_config "$d" pi >/dev/null 2>&1
        assert_eq "$img: the private key is copied to the boot partition" \
            "$(cat "$gh_dir/id_ed25519_github")" "$(cat "$d/rpi-setup-github-key")"
        assert_eq "$img: the public key is copied next to it" "$FLASH_GH_PUB" "$(cat "$d/rpi-setup-github-key.pub")"
        f="$d/user-data"; [[ "$img" == trixie ]] || f="$d/firstrun.sh"
        assert_fails "$img: the first-boot file does not hold the private key" grep -q 'PRIVATE KEY' "$f"
        assert_ok "$img: the key-moving script sets mode 600 and the user as owner" grep -q 'install -m 0600 -o "$U"' "$f"
        assert_ok "$img: the key-moving script is for the login user" grep -q "U='pi'" "$f"
        [[ "$img" == trixie ]] || assert_ok "bookworm: firstrun.sh with the GitHub key is valid bash" bash -n "$f"
    done
    d="$(new_bootfs trixie)"; write_firstboot_config "$d" pi >/dev/null 2>&1
    assert_ok "trixie: user-data enables the one-shot service" grep -qx '  - \[systemctl, enable, rpi-setup-github-key.service\]' "$d/user-data"
    if [[ "$have_yaml" -eq 1 ]]; then
        assert_eq "trixie: user-data with the GitHub key is valid YAML" "/usr/local/sbin/rpi-setup-github-key" \
            "$(yaml_get "$d/user-data" "d['write_files'][0]['path']")"
        yaml_get "$d/user-data" "d['write_files'][0]['content']" >"$TMP/mover.sh"
        assert_ok "trixie: the key-moving script is valid sh" sh -n "$TMP/mover.sh"
    fi
    remove_github_key
    assert_eq "remove_github_key deletes the temp key directory" "gone" "$([[ -e "$gh_dir" ]] && echo there || echo gone)"
else
    skip "GitHub key cases need ssh-keygen"
fi
reset_flash_vars

# --- disks: in-use detection, listing order, one list for the menu -------------------
# A fake sysfs tree: sdx is a USB stick, sdy holds an LVM PV (a holder on its
# partition), sdz is swap. Nothing is mounted (lsblk knows no such devices).
fake_disk() { # fake_disk NAME MODEL BUS   (BUS is part of the resolved sysfs path)
    local d="$TMP/sys/devices/$3/block/$1"
    mkdir -p "$d/device" "$d/holders" "$d/${1}1/holders" "$TMP/sys/class/block"
    printf '31116288\n' >"$d/size"
    printf '0\n' >"$d/removable"
    printf '%s\n' "$2" >"$d/device/model"
    ln -s "$d" "$TMP/sys/class/block/$1"
    ln -s "$d/${1}1" "$TMP/sys/class/block/${1}1"
    printf '1\n' >"$d/${1}1/partition"
}
fake_disk sdx 'USB Stick' usb1
fake_disk sdy 'Internal SSD' pci0
fake_disk sdz 'Other Disk' pci0
mkdir -p "$TMP/sys/class/block/sdy1/holders/dm-0"
printf 'Filename Type Size Used Priority\n/dev/sdz1 partition 1 0 -2\n' >"$TMP/swaps"
SYS_BLOCK="$TMP/sys/class/block" PROC_SWAPS="$TMP/swaps"
assert_eq "a disk with no mount, holder or swap is free" "" "$(disk_in_use sdx)"
assert_contains "a disk whose partition has a holder is in use" "used by dm-0" "$(disk_in_use sdy)"
# /proc/swaps names /dev/sdz1; readlink -f keeps a missing path as it is.
assert_contains "a disk with active swap is in use" "active swap on /dev/sdz1" "$(disk_in_use sdz)"
list="$(list_candidates)"
assert_eq "list_candidates puts the free disk first" "/dev/sdx" "$(head -n1 <<<"$list" | cut -f1)"
assert_eq "list_candidates lists all three" "3" "$(wc -l <<<"$list")"
assert_contains "list_candidates marks a disk in use" $'/dev/sdy\t' "$(grep 'IN USE: used by dm-0' <<<"$list")"
assert_contains "list_candidates shows the bus" "(USB)" "$(head -n1 <<<"$list")"
assert_eq "list_candidates does not mark the free disk" "" "$(head -n1 <<<"$list" | grep 'IN USE' || true)"
SYS_BLOCK=/sys/class/block PROC_SWAPS=/proc/swaps
# The disk holding / is in use, whatever it is called, and is refused.
root_dev="$(awk '$2 == "/" {print $1; exit}' /proc/mounts)"
root_disk=""
if [[ -b "$root_dev" ]] && command -v lsblk >/dev/null 2>&1; then
    root_disk="$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -n1)"
    [[ -n "$root_disk" ]] || root_disk="${root_dev##*/}"
fi
if [[ -n "$root_disk" && -b "/dev/$root_disk" ]]; then
    assert_contains "the disk holding / is in use" "mounted at /" "$(disk_in_use "$root_disk")"
    assert_fails "confirm_device refuses the disk holding /" confirm_device "/dev/$root_disk"
    assert_contains "confirm_device says why" "is in use (mounted at /" "$( (confirm_device "/dev/$root_disk") 2>&1 || true)"
    id="$(disk_identity "/dev/$root_disk")"
    assert_eq "disk_identity is stable" "$id" "$(disk_identity "/dev/$root_disk")"
    if [[ -n "$id" ]]; then pass "disk_identity knows the root disk"; else fail "disk_identity is empty for /dev/$root_disk"; fi
else
    skip "root disk cases (/ is not on a plain block device here)"
fi
# The menu is numbered from one listing: a disk showing up in between must not
# renumber the choice.
printf '0' >"$TMP/list-calls"
list_candidates() {
    local n; n="$(cat "$TMP/list-calls")"; printf '%d' "$((n + 1))" >"$TMP/list-calls"
    if [[ "$n" -eq 0 ]]; then printf '/dev/sdx\tfree\n/dev/sdy\tfree\n'; else printf '/dev/mmcblk0\tnew\n/dev/sdx\tfree\n/dev/sdy\tfree\n'; fi
}
assert_eq "pick_device resolves the number against the list it showed" "/dev/sdy" "$(pick_device <<<'2' 2>/dev/null)"
assert_eq "pick_device lists only once" "1" "$(cat "$TMP/list-calls")"
assert_eq "pick_device takes a /dev node as typed" "/dev/sdq" "$(pick_device <<<'/dev/sdq' 2>/dev/null)"
assert_fails "pick_device refuses a number past the list" eval 'pick_device <<<"4"'
assert_fails "pick_device refuses 0" eval 'pick_device <<<"0"'
unset -f list_candidates
# Before writing, the target must still be the confirmed disk (any block
# device will do here: the identity and in-use lookups are stubbed).
blk=/dev/loop0
[[ -b "$blk" ]] || blk="/dev/$root_disk"
if [[ -b "$blk" ]]; then
    DEV_IDENTITY="14.9G Card 1234"
    disk_identity() { echo "14.9G Card 1234"; }
    disk_in_use() { :; }
    assert_ok "check_device_unchanged passes for the same disk" check_device_unchanged "$blk"
    disk_identity() { echo "931G Backup 9999"; }
    assert_fails "check_device_unchanged stops when the disk changed" check_device_unchanged "$blk"
    assert_contains "check_device_unchanged says what it found" "is not the disk that was confirmed" \
        "$( (check_device_unchanged "$blk") 2>&1 || true)"
    disk_identity() { echo "14.9G Card 1234"; }
    disk_in_use() { echo "mounted at /mnt/x"; }
    assert_fails "check_device_unchanged stops when the disk is in use now" check_device_unchanged "$blk"
    unset -f disk_identity disk_in_use
    DEV_IDENTITY=""
else
    skip "check_device_unchanged cases need a block device"
fi
assert_fails "check_device_unchanged stops when the disk is gone" check_device_unchanged "$TMP/gone"
assert_contains "a vanished disk is explained" "is gone" "$( (check_device_unchanged "$TMP/gone") 2>&1 || true)"
# flash.sh unmounts a stale boot partition first and on exit, and resolves the device once.
src="$(cat "$ROOT/host/flash.sh")"
assert_contains "a stale mount is unmounted before mounting the card" "still mounted from an earlier run" "$src"
assert_contains "main sets the cleanup trap" "trap cleanup EXIT" "$src"
assert_contains "the device is resolved once" 'DEV="$(readlink -f "$DEV")"' "$src"

# --- CLI ---------------------------------------------------------------------------
help="$(bash "$ROOT/host/flash.sh" -h 2>&1)"
assert_contains "usage lists the hostname flag" "-n HOSTNAME" "$help"
assert_contains "usage lists the SSH key flag" "-a PUBKEY_FILE" "$help"
assert_contains "usage lists the no-eject flag" "-E " "$help"
if [[ $EUID -eq 0 ]]; then
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -k -n homepi -d /dev/null 2>&1 || true)"
    assert_contains "-k with a first-boot setting stops before any disk work" "cannot be combined" "$out"
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -k -g true -d /dev/null 2>&1 || true)"
    assert_contains "-k with -g true (not yet normalised) stops too" "cannot be combined" "$out"
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -k -i "$TMP/none.img" -d /dev/null 2>&1 || true)"
    assert_contains "a node that is no disk is refused (/dev/null)" "Not a block device" "$out"
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -n bad_name -d /dev/null 2>&1 || true)"
    assert_contains "an invalid hostname stops before any disk work" "Invalid hostname" "$out"
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -u Bad -p longpassword -i "$TMP/none.img" -d /dev/null 2>&1 </dev/null || true)"
    assert_contains "an invalid username stops before the image and the card" "Invalid username" "$out"
    out="$(RPI_SETUP_CONFIG_DIR="$TMP/nocfg" bash "$ROOT/host/flash.sh" -u pi -i "$TMP/none.img" -d /dev/null 2>&1 </dev/null || true)"
    assert_contains "a missing password stops before the image and the card" "Password required" "$out"
else
    skip "CLI validation cases need root (flash.sh checks for root first)"
fi

finish_tests
