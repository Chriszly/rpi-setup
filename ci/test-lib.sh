#!/usr/bin/env bash
# test-lib.sh - unit tests for the pure helpers in lib/common.sh and host/flash.sh.
#
# Sourcing host/flash.sh loads lib/common.sh too and defines the functions
# without running main(). Tests that touch /var/lib/rpi-setup (assign_uid,
# find_free_uid) only run as root and clean up after themselves.
#
# Run: bash ci/test-lib.sh        (sudo bash ci/test-lib.sh for the root-only tests)
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
