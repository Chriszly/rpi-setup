#!/usr/bin/env bash
# test-task-pihole.sh - unit tests for tasks/pihole.sh: PIHOLE_CONFIRM decides
# without a question, and a generated container password is printed and saved
# before the container starts (so a failed first start does not lose it).
# Docker, ports and save_secret are stubbed; nothing outside a temp folder changes.
#
# Run: bash ci/test-task-pihole.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RPI_SETUP_ROOT="$ROOT"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/pihole.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- PIHOLE_CONFIRM: no prompt, the setting decides ---------------------------
# confirm_with VALUE: pihole_confirm_installer in a subshell (die exits it).
confirm_with() { (PIHOLE_CONFIRM="$1"; pihole_confirm_installer) </dev/null >/dev/null 2>&1; }
assert_ok "PIHOLE_CONFIRM=yes runs the installer" confirm_with yes
assert_fails "PIHOLE_CONFIRM=no fails the task" confirm_with no
assert_fails "PIHOLE_CONFIRM=maybe is rejected" confirm_with maybe
out="$(PIHOLE_CONFIRM=yes pihole_confirm_installer </dev/null 2>&1)"
assert_contains "the curl|bash warning is still printed" 'curl ... | bash' "$out"
assert_eq "no question is asked" "" "$(grep -n 'read -r -p' "$ROOT/tasks/pihole.sh" || true)"

# --- PIHOLE_DOCKER: generated password saved before the container starts -----
export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
require_image_ref() { :; }
container_require_64bit() { :; }
container_require_docker() { :; }
container_copy_once() { return 1; }
container_pull() { :; }
container_stop_native() { :; }
container_state() { :; }
port_owner() { return 1; }
save_secret() { printf '%s=%s\n' "$2" "$3" >>"$TMP/saved"; }
container_up() { echo "container_up saved=[$(cat "$TMP/saved" 2>/dev/null)]"; exit 1; }  # dies like a failed start

out="$( (unset PIHOLE_PASSWORD; PIHOLE_INTERFACE=lo PIHOLE_WEB_PORT=8080 run_pihole_container 1.1.1.1) 2>&1 || true)"
saved="$(sed -nE 's/^PIHOLE_PASSWORD=//p' "$TMP/saved" 2>/dev/null || true)"
assert_ok "a generated password is saved" test -n "$saved"
assert_contains "it is saved before container_up" "container_up saved=[PIHOLE_PASSWORD=$saved]" "$out"
assert_contains "it is printed even when the start fails" "Generated web admin password: $saved" "$out"

rm -f "$TMP/saved"
out="$( (PIHOLE_PASSWORD=given PIHOLE_INTERFACE=lo PIHOLE_WEB_PORT=8080 run_pihole_container 1.1.1.1) 2>&1 || true)"
assert_eq "PIHOLE_PASSWORD is not saved as generated" "" "$(cat "$TMP/saved" 2>/dev/null || true)"

finish_tests
