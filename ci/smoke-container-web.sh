#!/usr/bin/env bash
# smoke-container-web.sh - WEB_DOCKER end to end on a runner with Docker and
# systemd: native nginx with a page of your own, switch to the container (the
# page and port come along, native nginx stops), re-run without a restart,
# then switch back to native.
#
# Run: sudo bash ci/smoke-container-web.sh   (installs nginx; CI runners only)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

PORT=8090
setup() { env "$@" bash "$ROOT/setup.sh" web; }
page() { curl -fsS --max-time 5 "http://127.0.0.1:${1:-$PORT}/${2:-}" 2>/dev/null || true; }
started() { docker inspect -f '{{.State.StartedAt}}' web 2>/dev/null || true; }

setup WEB_DOCKER=no WEB_PORT=$PORT
echo 'my own page' >/var/www/html/index.html
assert_eq "native nginx serves the page" "my own page" "$(page)"

setup WEB_DOCKER=yes
assert_eq "the container serves the native page on the native port" "my own page" "$(page)"
assert_fails "native nginx is stopped" systemctl is-active --quiet nginx
assert_eq "the container runs as 'web'" "running" "$(docker inspect -f '{{.State.Status}}' web 2>/dev/null)"
assert_contains "nginx listens on $PORT in the container's config" "listen $PORT;" "$(cat /opt/web/conf/default.conf)"
assert_contains "the container serves the service list" '"services":[' "$(page "$PORT" services.json)"
assert_ok "the service list timer is on" systemctl is-enabled --quiet rpi-setup-web-links.timer

before="$(started)"
setup WEB_DOCKER=yes
assert_eq "a re-run leaves the running container alone" "$before" "$(started)"

setup WEB_DOCKER=yes WEB_PORT=8091
assert_eq "WEB_PORT moves the container" "my own page" "$(page 8091)"

setup WEB_DOCKER=no WEB_PORT=$PORT
assert_eq "switching back removes the container" "" "$(started)"
assert_ok "native nginx runs again" systemctl is-active --quiet nginx
assert_eq "native nginx serves the page again" "my own page" "$(page)"

finish_tests
