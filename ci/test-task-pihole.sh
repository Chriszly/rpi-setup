#!/usr/bin/env bash
# test-task-pihole.sh - unit tests for tasks/pihole.sh: the installer runs
# without a question, and a generated container password is printed and saved
# before the container starts (so a failed first start does not lose it).
# Docker, ports and save_secret are stubbed; nothing outside a temp folder changes.
#
# Run: bash ci/test-task-pihole.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
export RPI_SETUP_ROOT="$ROOT"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/pihole.sh"

# --- The installer: a warning, never a question --------------------------------
assert_contains "the curl|bash warning is printed" 'curl ... | bash' "$(declare -f run_pihole)"
assert_contains "the installer always runs unattended" 'bash /dev/stdin --unattended' "$(declare -f run_pihole)"
assert_eq "no question is asked" "" "$(grep -n 'read -r -p' "$ROOT/tasks/pihole.sh" || true)"

# --- PIHOLE_DOCKER: generated password saved before the container starts -----
export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
stub_container_helpers
container_copy_once() { return 1; }
save_secret() { printf '%s=%s\n' "$2" "$3" >>"$TMP/saved"; }
container_up() { echo "container_up saved=[$(cat "$TMP/saved" 2>/dev/null)]"; exit 1; }  # dies like a failed start

out="$( (unset PIHOLE_PASSWORD; PIHOLE_WEB_PORT=8080 run_pihole_container lo 1.1.1.1) 2>&1 || true)"
saved="$(sed -nE 's/^PIHOLE_PASSWORD=//p' "$TMP/saved" 2>/dev/null || true)"
assert_ok "a generated password is saved" test -n "$saved"
assert_contains "it is saved before container_up" "container_up saved=[PIHOLE_PASSWORD=$saved]" "$out"
assert_contains "it is printed even when the start fails" "Generated web admin password: $saved" "$out"

rm -f "$TMP/saved"
out="$( (PIHOLE_PASSWORD=given PIHOLE_WEB_PORT=8080 run_pihole_container lo 1.1.1.1) 2>&1 || true)"
assert_eq "PIHOLE_PASSWORD is not saved as generated" "" "$(cat "$TMP/saved" 2>/dev/null || true)"

finish_tests
