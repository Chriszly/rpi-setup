#!/usr/bin/env bash
# test-lib.sh - unit tests for the pure helpers in lib/common.sh and host/flash.sh.
#
# Sourcing host/flash.sh loads lib/common.sh too and defines the functions
# without running main(). Tests that touch /var/lib/rpi-setup (assign_uid,
# find_free_uid) only run as root and clean up after themselves.
#
# Run: bash ci/test-lib.sh        (sudo bash ci/test-lib.sh for the root-only tests)
# Many cases pass literal $ strings (settings values, eval bodies) on purpose.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/host/flash.sh"

# --- lib/common.sh: net_base --------------------------------------------------
assert_eq "net_base /24"  "192.168.1.0/24"   "$(net_base 192.168.1.50/24)"
assert_eq "net_base /8"   "10.0.0.0/8"       "$(net_base 10.20.30.40/8)"
assert_eq "net_base /12"  "172.16.0.0/12"    "$(net_base 172.20.5.9/12)"
assert_eq "net_base /16"  "192.168.0.0/16"   "$(net_base 192.168.77.5/16)"
assert_eq "net_base /32"  "192.168.1.50/32"  "$(net_base 192.168.1.50/32)"
assert_eq "net_base /25 upper half" "192.168.1.128/25" "$(net_base 192.168.1.200/25)"
assert_fails "net_base rejects /0"            net_base 1.2.3.4/0
assert_fails "net_base rejects /33"           net_base 1.2.3.4/33
assert_fails "net_base rejects missing prefix" net_base 1.2.3.4
assert_fails "net_base rejects non-numeric prefix" net_base 1.2.3.4/abc

# --- lib/common.sh: real_user -------------------------------------------------
assert_eq "real_user prefers SUDO_USER" "alice" "$(SUDO_USER=alice USER=bob real_user)"
assert_eq "real_user falls back to USER" "bob"  "$(SUDO_USER='' USER=bob real_user)"
assert_eq "real_user falls back to root" "root" "$(SUDO_USER='' USER='' real_user)"

# --- lib/common.sh: need_root / die -------------------------------------------
if [[ $EUID -ne 0 ]]; then
    assert_fails "need_root fails for non-root" need_root
else
    assert_ok "need_root passes for root" need_root
fi
assert_fails "die exits non-zero" die "boom"
assert_contains "die prints message to stderr" "boom" "$( (die "boom") 2>&1 >/dev/null || true)"

# --- lib/common.sh: assign_uid / find_free_uid (root only) --------------------
if [[ $EUID -eq 0 ]] && command -v getent >/dev/null 2>&1; then
    uid_dir=/var/lib/rpi-setup/uids
    svc="citest-$$"
    cleanup_uids() { rm -f "$uid_dir/$svc" "$uid_dir/$svc-taken"; }
    trap cleanup_uids EXIT

    first="$(assign_uid "$svc")"
    if [[ "$first" =~ ^[0-9]+$ ]] && (( first >= 10000 )); then
        pass "assign_uid returns a numeric UID >= 10000 ($first)"
    else
        fail "assign_uid returned '$first'"
    fi
    assert_eq "assign_uid is stable across calls" "$first" "$(assign_uid "$svc")"
    assert_eq "assign_uid persists the UID" "$first" "$(<"$uid_dir/$svc")"

    if getent passwd "$first" >/dev/null 2>&1 || getent group "$first" >/dev/null 2>&1; then
        fail "assign_uid handed out a UID that already exists on the system ($first)"
    else
        pass "assign_uid avoids existing system accounts"
    fi

    # A UID recorded for another service must not be handed out again.
    next="$(find_free_uid)"
    printf '%s\n' "$next" >"$uid_dir/$svc-taken"
    after="$(find_free_uid)"
    if [[ "$after" != "$next" ]] && [[ "$after" != "$first" ]]; then
        pass "find_free_uid skips UIDs already assigned to other services"
    else
        fail "find_free_uid returned an already-assigned UID ($after)"
    fi
else
    skip "assign_uid / find_free_uid tests need root and getent"
fi

# --- lib/common.sh: compose_is_up (needs a working docker) --------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # 'docker ps' exits 0 even with no match, so this must inspect the output.
    assert_fails "compose_is_up is false for a container that does not exist" \
        compose_is_up "rpi-setup-no-such-container-$$"
else
    skip "compose_is_up test needs a running docker daemon"
fi

# --- lib/common.sh: port_owner (ss mocked) ------------------------------------
ss() {
    case "$*" in
        *':80') printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("pihole-FTL",pid=812,fd=24))' ;;
        *':81') printf '%s\n' 'LISTEN 0 511 0.0.0.0:81 0.0.0.0:*' ;;
        *) : ;;
    esac
}
assert_eq "port_owner names the listening process" "pihole-FTL" "$(port_owner 80)"
assert_eq "port_owner says 'unknown' without process info" "unknown" "$(port_owner 81)"
assert_fails "port_owner fails when nothing listens" port_owner 82
unset -f ss

# --- lib/common.sh: task_in_container (docker mocked) -------------------------
ctr="$(mktemp -d)"
install -d "$ctr/web" "$ctr/monitoring" "$ctr/samba"
touch "$ctr/web/docker-compose.yml" "$ctr/monitoring/docker-compose.yml"
docker() { [[ "$1 $2 $3" == "inspect --type container" && " web netdata " == *" $4 "* ]]; }
RPI_SETUP_CONTAINER_ROOT="$ctr"
assert_ok "task_in_container: compose file and container" task_in_container web
assert_ok "task_in_container: container named differently" task_in_container monitoring netdata
assert_fails "task_in_container: container removed (back to native)" task_in_container monitoring
assert_fails "task_in_container: no compose file" task_in_container samba
unset RPI_SETUP_CONTAINER_ROOT
unset -f docker
rm -rf "$ctr"

# --- lib/common.sh: apt_install / apt_update_now (apt-get mocked, root only) --
if [[ $EUID -eq 0 ]]; then
    apt_log="$(mktemp)"
    stamp=/var/lib/rpi-setup/apt-updated
    had_stamp=0; [[ -f "$stamp" ]] && had_stamp=1
    apt-get() { printf '%s\n' "$*" >>"$apt_log"; }
    install -m 0755 -d /var/lib/rpi-setup
    touch "$stamp"
    apt_install foo
    assert_eq "apt_install skips 'apt-get update' within the hour" "0" "$(grep -c '^update' "$apt_log" || true)"
    assert_contains "apt_install never stops at dpkg conffile prompts" "--force-confold" "$(cat "$apt_log")"
    apt_update_now
    assert_eq "apt_update_now refreshes even within the hour" "1" "$(grep -c '^update' "$apt_log" || true)"
    unset -f apt-get
    rm -f "$apt_log"
    [[ $had_stamp -eq 1 ]] || rm -f "$stamp"
else
    skip "apt_install / apt_update_now tests need root"
fi

# --- lib/common.sh: task settings ---------------------------------------------
assert_eq "config_value keeps a plain value"          "abc"          "$(config_value 'abc')"
assert_eq "config_value trims whitespace"             "abc"          "$(config_value '  abc  ')"
assert_eq "config_value drops a trailing comment"     "abc"          "$(config_value 'abc # note')"
assert_eq "config_value keeps # inside a word"        "a#b"          "$(config_value 'a#b')"
assert_eq "config_value unquotes double quotes"       "a b #c"       "$(config_value '"a b #c"  # note')"
assert_eq "config_value unquotes single quotes"       'x"y $HOME'    "$(config_value "'x\"y \$HOME'")"
assert_eq "config_value reads an empty value"         ""             "$(config_value '')"
assert_eq "config_value reads empty quotes"           ""             "$(config_value "''")"
for v in 'plain' 'with space' 'a #b' 'dollar $x' "it's" 'say "hi"'; do
    assert_eq "config_quote round-trips: $v" "$v" "$(config_value "$(config_quote "$v")")"
done
assert_fails "config_quote refuses a value with both quote kinds" config_quote "a'b\"c"

cfg="$(mktemp -d)"
printf '# comment\n\nSAMBA_USER=alice\nexport SAMBA_SHARE_NAME="my share" # c\nSAMBA_PASSWORD=\r\n' >"$cfg/samba.env"
out="$(unset SAMBA_USER SAMBA_SHARE_NAME SAMBA_PASSWORD; load_task_config samba "$cfg/samba.env" >/dev/null; declare -p SAMBA_USER SAMBA_SHARE_NAME SAMBA_PASSWORD)"
assert_contains "load_task_config reads KEY=value"            'SAMBA_USER="alice"' "$out"
assert_contains "load_task_config accepts export and quotes"  'SAMBA_SHARE_NAME="my share"' "$out"
assert_contains "load_task_config reads empty values (CRLF)"  'SAMBA_PASSWORD=""' "$out"
assert_eq "load_task_config lets the environment win" "bob" \
    "$(SAMBA_USER=bob; load_task_config samba "$cfg/samba.env" >/dev/null; printf '%s' "$SAMBA_USER")"
printf 'PATH=/tmp/evil\n' >"$cfg/web.env"
assert_fails "load_task_config refuses keys of other tasks (PATH)" load_task_config web "$cfg/web.env"
printf 'WEB_PORT 80\n' >"$cfg/web.env"
assert_fails "load_task_config refuses a line without =" load_task_config web "$cfg/web.env"
assert_contains "load_task_config names the bad line, not its content" "line 1" \
    "$( (load_task_config web "$cfg/web.env") 2>&1 || true)"
assert_ok "load_task_config accepts a missing file" load_task_config web "$cfg/missing.env"
printf 'SAMBA_PASSWORD=secret\n' >"$cfg/loose.env"
chmod 0644 "$cfg/loose.env"
assert_contains "load_task_config warns about a readable password file" "chmod 600" \
    "$( (load_task_config samba "$cfg/loose.env") 2>&1 >/dev/null)"
chmod 0600 "$cfg/loose.env"
assert_eq "load_task_config is quiet about a private password file" "" \
    "$( (load_task_config samba "$cfg/loose.env") 2>&1 >/dev/null)"

# split_config: the central example splits into one file per task template.
printf 'SAMBA_PASSWORD="p #1"\nWEB_PORT=8081\n' >"$cfg/rpi-setup.env"
chmod 0600 "$cfg/rpi-setup.env"
( RPI_SETUP_CONFIG_DIR="$cfg" split_config "$cfg/rpi-setup.env" ) >/dev/null
assert_ok "split_config writes one file per task" test -f "$cfg/local/samba.env" -a -f "$cfg/local/teamspeak.env"
assert_eq "split_config output is private" "600" "$(stat -c %a "$cfg/local/samba.env")"
assert_eq "split_config keeps the value" "p #1" \
    "$(unset SAMBA_PASSWORD; load_task_config samba "$cfg/local/samba.env" >/dev/null; printf '%s' "$SAMBA_PASSWORD")"
assert_eq "split_config lists every name of the task" "$(task_setting_names samba | xargs)" \
    "$(sed -nE 's/^([A-Z0-9_]+)=.*/\1/p' "$cfg/local/samba.env" | xargs)"
assert_contains "split_config routes each name to its task" "WEB_PORT='8081'" "$(cat "$cfg/local/web.env")"
printf 'SAMBA_PASWORD=typo\n' >"$cfg/rpi-setup.env"
assert_fails "split_config stops on an unknown name" eval 'RPI_SETUP_CONFIG_DIR="$cfg" split_config "$cfg/rpi-setup.env"'
assert_ok "split_config accepts the committed example" eval \
    'RPI_SETUP_CONFIG_DIR="$cfg" split_config "$ROOT/config/rpi-setup.env.example" >/dev/null'
assert_fails "split_config explains a missing central file" eval 'RPI_SETUP_CONFIG_DIR="$cfg" split_config "$cfg/nope.env"'
rm -rf "$cfg"

for v in yes YES true on 1; do assert_ok "setting_on: $v" eval "X=$v; setting_on X"; done
for v in no False off 0; do assert_fails "setting_on: $v is off" eval "X=$v; setting_on X"; done
assert_contains "setting_on dies naming the setting" "X must be yes or no" "$( (X=maybe; setting_on X) 2>&1 || true)"
assert_ok    "require_port accepts 8080"  eval 'P=8080; require_port P'
assert_fails "require_port rejects 0"     eval 'P=0; require_port P'
assert_fails "require_port rejects 65536" eval 'P=65536; require_port P'
assert_fails "require_port rejects text"  eval 'P=http; require_port P'
assert_ok    "valid_hostname accepts homepi-1" valid_hostname homepi-1
assert_fails "valid_hostname rejects a dot"    valid_hostname home.pi
assert_fails "valid_hostname rejects a leading -" valid_hostname -pi
assert_ok    "require_image_ref accepts repo/name:tag" eval 'I=ghcr.io/netalertx/netalertx:latest; require_image_ref I'
assert_fails "require_image_ref rejects spaces" eval 'I="a b"; require_image_ref I'

s1="$(gen_secret 24)"; s2="$(gen_secret 24)"
if [[ "$s1" =~ ^[A-Za-z0-9]{24}$ && "$s1" != "$s2" ]]; then
    pass "gen_secret makes distinct 24-character alphanumeric secrets"
else
    fail "gen_secret produced '$s1' / '$s2'"
fi

tmp="$(mktemp -d)"
assert_ok    "write_if_changed writes a new file"      eval "echo a | write_if_changed '$tmp/f' 0600"
assert_fails "write_if_changed reports unchanged"      eval "echo a | write_if_changed '$tmp/f' 0600"
assert_eq    "write_if_changed applies the mode"       "600" "$(stat -c %a "$tmp/f")"
assert_ok    "write_if_changed reports a change"       eval "echo b | write_if_changed '$tmp/f'"
assert_eq    "write_if_changed wrote the new content"  "b" "$(cat "$tmp/f")"

printf '[global]\n\tworkgroup = W\n[web]\n\t# default port = 1\n\tbind to = x\n' >"$tmp/ini"
assert_ok    "ini_set adds a key to a section" ini_set "$tmp/ini" web 'default port' 2000
assert_contains "ini_set skips commented keys" $'\t# default port = 1' "$(cat "$tmp/ini")"
assert_contains "ini_set wrote the key" $'\tdefault port = 2000' "$(cat "$tmp/ini")"
assert_fails "ini_set is idempotent" ini_set "$tmp/ini" web 'default port' 2000
assert_ok    "ini_set replaces a value" ini_set "$tmp/ini" web 'bind to' 127.0.0.1
assert_eq    "ini_set leaves one line per key" "1" "$(grep -c 'bind to' "$tmp/ini")"
assert_ok    "ini_set appends a missing section" ini_set "$tmp/ini" new k v
assert_contains "ini_set appended the section" $'[new]\n\tk = v' "$(cat "$tmp/ini")"

printf 'dtparam=audio=on\n[all]\n' >"$tmp/config.txt"
assert_fails "boot_config_block leaves config.txt alone without options" eval "printf '' | boot_config_block '$tmp/config.txt'"
assert_ok    "boot_config_block adds its block" eval "printf 'dtparam=pciex1_gen=3\n' | boot_config_block '$tmp/config.txt'"
assert_fails "boot_config_block is idempotent" eval "printf 'dtparam=pciex1_gen=3\n' | boot_config_block '$tmp/config.txt'"
assert_contains "boot_config_block keeps the original lines" "dtparam=audio=on" "$(cat "$tmp/config.txt")"
assert_ok    "boot_config_block removes its block" eval "printf '' | boot_config_block '$tmp/config.txt'"
assert_eq    "boot_config_block restores the file" $'dtparam=audio=on\n[all]' "$(cat "$tmp/config.txt")"

printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$tmp/model"
assert_ok    "is_pi5 on a Pi 5"  eval "RPI_SETUP_MODEL_FILE='$tmp/model' is_pi5"
assert_ok    "is_pi on a Pi 5"   eval "RPI_SETUP_MODEL_FILE='$tmp/model' is_pi"
printf 'Raspberry Pi Compute Module 5 Rev 1.0\0' >"$tmp/model"
assert_ok    "is_pi5 on a CM5"   eval "RPI_SETUP_MODEL_FILE='$tmp/model' is_pi5"
printf 'Raspberry Pi 4 Model B Rev 1.5\0' >"$tmp/model"
assert_fails "is_pi5 is false on a Pi 4" eval "RPI_SETUP_MODEL_FILE='$tmp/model' is_pi5"
assert_fails "is_pi5 is false off a Pi"  eval "RPI_SETUP_MODEL_FILE='$tmp/missing' is_pi5"
rm -rf "$tmp"

if [[ $EUID -eq 0 ]]; then
    sec=/var/lib/rpi-setup/secrets/citest-$$.env
    save_secret "citest-$$" A one
    save_secret "citest-$$" B two
    save_secret "citest-$$" A three
    assert_eq "save_secret replaces a key and keeps others" $'B=two\nA=three' "$(cat "$sec")"
    assert_eq "save_secret file is root-only" "600" "$(stat -c %a "$sec")"
    rm -f "$sec"
else
    skip "save_secret test needs root"
fi

# --- host/flash.sh: first_partition -------------------------------------------
assert_eq "first_partition sda"     "/dev/sda1"       "$(first_partition /dev/sda)"
assert_eq "first_partition vda"     "/dev/vda1"       "$(first_partition /dev/vda)"
assert_eq "first_partition mmcblk0" "/dev/mmcblk0p1"  "$(first_partition /dev/mmcblk0)"
assert_eq "first_partition nvme0n1" "/dev/nvme0n1p1"  "$(first_partition /dev/nvme0n1)"

# --- host/flash.sh: confirm_device --------------------------------------------
assert_fails "confirm_device rejects a non-block path" confirm_device /nonexistent/device
assert_contains "confirm_device explains the rejection" "Not a block device" \
    "$( (confirm_device /nonexistent/device) 2>&1 || true)"

# --- host/flash.sh: ask_credentials (non-interactive branches) ----------------
# USER/PASS are pre-set so ask_credentials never reaches its read prompts.
assert_ok    "ask_credentials accepts a valid user/password"   eval 'USER=pi PASS=longpassword; ask_credentials'
assert_fails "ask_credentials rejects an uppercase username"   eval 'USER=Pi PASS=longpassword; ask_credentials'
assert_fails "ask_credentials rejects a username with spaces"  eval 'USER="pi user" PASS=longpassword; ask_credentials'
assert_fails "ask_credentials rejects a colon in the password" eval 'USER=pi PASS=a:b; ask_credentials'
assert_contains "ask_credentials warns on short passwords" "shorter than 8" \
    "$( (USER=pi PASS=short ask_credentials) 2>&1 || true)"

# --- host/flash.sh: generate_hash ---------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    h="$(generate_hash 'correct horse')"
    if [[ "$h" == "\$6\$"* ]]; then
        pass "generate_hash produces a SHA-512 crypt hash"
    else
        fail "generate_hash produced '$h'"
    fi
else
    skip "generate_hash test needs openssl"
fi

# --- host/flash.sh: usage / -l do not need root --------------------------------
assert_contains "flash.sh -h prints usage" "Usage:" "$(bash "$ROOT/host/flash.sh" -h 2>&1)"
assert_ok "flash.sh -l lists candidate disks without root" bash "$ROOT/host/flash.sh" -l

finish_tests
