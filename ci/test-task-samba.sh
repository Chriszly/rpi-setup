#!/usr/bin/env bash
# test-task-samba.sh - unit tests for tasks/samba.sh with SAMBA_DOCKER=yes: a
# generated password is printed and saved before the container starts, so a
# failed first start (after which later runs read it from /opt/samba/password)
# does not lose it. Docker, ports and save_secret are stubbed; nothing outside
# a temp folder changes. Skipped if this machine already has a saved password.
#
# Run: bash ci/test-task-samba.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RPI_SETUP_ROOT="$ROOT"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/samba.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
require_image_ref() { :; }
container_require_64bit() { :; }
container_require_docker() { :; }
container_pull() { :; }
container_stop_native() { :; }
container_state() { :; }
port_owner() { return 1; }
pdbedit() { return 1; }
save_secret() { printf '%s=%s\n' "$2" "$3" >>"$TMP/saved"; }
container_up() { echo "container_up saved=[$(cat "$TMP/saved" 2>/dev/null)]"; exit 1; }  # dies like a failed start

u="$(id -un)"
[[ "$u" != root ]] || u=nobody
mkdir -p "$TMP/share"

if [[ -e /var/lib/rpi-setup/secrets/samba.env ]]; then
  skip "a saved Samba password exists on this machine"
else
  out="$( (unset SAMBA_PASSWORD; run_samba_container "$u" "$TMP/share" share no) 2>&1 || true)"
  saved="$(sed -nE 's/^SAMBA_PASSWORD=//p' "$TMP/saved" 2>/dev/null || true)"
  assert_ok "a generated password is saved" test -n "$saved"
  assert_eq "it is the one in the password file" "$saved" "$(cat "$TMP/opt/samba/password" 2>/dev/null)"
  assert_contains "it is saved before container_up" "container_up saved=[SAMBA_PASSWORD=$saved]" "$out"
  assert_contains "it is printed even when the start fails" "Generated Samba password for $u: $saved" "$out"

  # Re-run after the failed start: the password comes from the file, not new.
  rm -f "$TMP/saved"
  out="$( (unset SAMBA_PASSWORD; run_samba_container "$u" "$TMP/share" share no) 2>&1 || true)"
  assert_eq "a re-run keeps the password from the file" "$saved" "$(cat "$TMP/opt/samba/password")"
  assert_eq "a re-run does not generate another one" "" "$(cat "$TMP/saved" 2>/dev/null || true)"
fi

finish_tests
