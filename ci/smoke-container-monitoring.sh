#!/usr/bin/env bash
# smoke-container-monitoring.sh - MONITORING_DOCKER end to end on a runner
# with Docker and systemd: native netdata, switch to the container (native
# netdata stops, the dashboard keeps its port), re-run without a restart,
# then switch back to native.
#
# Run: sudo bash ci/smoke-container-monitoring.sh   (installs netdata; CI runners only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"

PORT=19999
setup() { env "$@" bash "$ROOT/setup.sh" monitoring; }
# HTTP status of the API, waiting up to 30 s for Netdata to finish starting (503).
api() {
    local code="" i
    for i in $(seq 1 30); do
        code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/info" 2>/dev/null || true)"
        [[ "$code" != 200 ]] || break
        sleep 1
    done
    printf '%s' "$code"
}
started() { docker inspect -f '{{.State.StartedAt}}' netdata 2>/dev/null || true; }

setup MONITORING_DOCKER=no
assert_eq "native netdata answers" "200" "$(api)"

setup MONITORING_DOCKER=yes
assert_eq "the container answers on the same port" "200" "$(api)"
assert_fails "native netdata is stopped" systemctl is-active --quiet netdata
assert_eq "the container is healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' netdata 2>/dev/null)"
assert_ok "telemetry is off" test -e /opt/monitoring/config/.opt-out-from-anonymous-statistics

before="$(started)"
setup MONITORING_DOCKER=yes
assert_eq "a re-run leaves the running container alone" "$before" "$(started)"

setup MONITORING_DOCKER=no
assert_eq "switching back removes the container" "" "$(started)"
assert_ok "native netdata runs again" systemctl is-active --quiet netdata

finish_tests
