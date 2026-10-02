#!/usr/bin/env bash
# test-task-usagecontrol.sh - unit tests for tasks/usagecontrol.sh: the
# compose file it writes, and the checks that stop it before anything changes.
#
# Run: bash ci/test-task-usagecontrol.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/usagecontrol.sh"

# --- the compose file -----------------------------------------------------------
out="$(usagecontrol_compose ghcr.io/chriszly/usage-control:1.2.3 8090)"
assert_contains "compose: image" 'image: "ghcr.io/chriszly/usage-control:1.2.3"' "$out"
assert_contains "compose: port on the host" '"8090:8080"' "$out"
assert_contains "compose: host /proc read-only" "/proc:/host/proc:ro" "$out"
assert_contains "compose: host /sys read-only" "/sys:/host/sys:ro" "$out"
assert_contains "compose: no capabilities" "- ALL" "$out"
assert_contains "compose: read-only file system" "read_only: true" "$out"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  printf '%s\n' "$out" >"$TMP/docker-compose.yml"
  assert_ok "compose: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
else
  skip "compose: docker compose not installed"
fi

# --- settings are checked before anything changes ------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
port_owner() { return 1; }
dpkg() { echo arm64; }
( USAGECONTROL_PORT=70000; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad port stops the task" "USAGECONTROL_PORT" "$(cat "$TMP/err")"
( USAGECONTROL_IMAGE='Bad Image'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad image stops the task" "USAGECONTROL_IMAGE must be a Docker image" "$(cat "$TMP/err")"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  port_owner() { echo nginx; }
  run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "port held by another program stops the task" "Port 8080 is used by nginx" "$(cat "$TMP/err")"
assert_ok "port held: Docker was not touched" test ! -e "$TMP/reached"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  dpkg() { echo armhf; }
  run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "32-bit OS stops the task" "needs a 64-bit OS" "$(cat "$TMP/err")"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_usagecontrol ) >/dev/null 2>&1 || true
assert_ok "port held by Docker's proxy goes on to Docker" test -e "$TMP/reached"
unset -f container_require_docker port_owner dpkg

finish_tests
