#!/usr/bin/env bash
# smoke-container-samba.sh - SAMBA_DOCKER end to end on a runner with Docker
# and systemd: native smbd, a switch without SAMBA_PASSWORD stops before
# changing anything, a switch with it moves the share into the container
# (same files, same owner), a re-run changes nothing, then back to native.
#
# Run: sudo bash ci/smoke-container-samba.sh   (installs samba, adds a user; CI runners only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"

U=smbci
PW=ci-Passw0rd
id "$U" >/dev/null 2>&1 || useradd -m "$U"
SHARE="/home/$U/nas-share"
setup() { env SAMBA_USER="$U" "$@" bash "$ROOT/setup.sh" samba; }
started() { docker inspect -f '{{.State.StartedAt}}' samba 2>/dev/null || true; }
# smb <command>: run smbclient against the share as $U (from the image).
smb() {
    docker run --rm --network host --entrypoint smbclient "${SAMBA_IMAGE:-crazymax/samba:latest}" \
        //127.0.0.1/nas-share -U "$U%$PW" -c "$1" 2>&1 || true
}

setup SAMBA_DOCKER=no SAMBA_PASSWORD="$PW"
echo native >"$SHARE/from-native.txt"
chown "$U:$U" "$SHARE/from-native.txt"

assert_fails "switching without SAMBA_PASSWORD stops" setup SAMBA_DOCKER=yes
assert_ok "and leaves native smbd running" systemctl is-active --quiet smbd

setup SAMBA_DOCKER=yes SAMBA_PASSWORD="$PW"
assert_fails "native smbd is stopped" systemctl is-active --quiet smbd
assert_eq "the container is running" "running" "$(docker inspect -f '{{.State.Status}}' samba 2>/dev/null)"
assert_contains "the share shows the native files" "from-native.txt" "$(smb ls)"
smb 'mkdir from-container' >/dev/null
assert_eq "files written through the container belong to $U" "$U" "$(stat -c %U "$SHARE/from-container" 2>/dev/null)"

before="$(started)"
setup SAMBA_DOCKER=yes
assert_eq "a re-run without SAMBA_PASSWORD keeps the container" "$before" "$(started)"

setup SAMBA_DOCKER=no
assert_eq "switching back removes the container" "" "$(started)"
assert_ok "native smbd runs again" systemctl is-active --quiet smbd

finish_tests
