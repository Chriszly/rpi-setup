#!/usr/bin/env bash
# smoke-container-web-pihole.sh - the start page takes port 80 from a Pi-hole
# container (tasks/web.sh web_move_pihole, #104) on a runner with Docker and
# systemd: Pi-hole in its container on port 80 first, then "setup.sh web"
# with the default ports moves the admin page to 8080, rewrites the Pi-hole
# compose file, and nginx answers on 80 with the admin page linked at 8080.
# A re-run of either task then changes nothing.
#
# Run: sudo bash ci/smoke-container-web-pihole.sh   (frees port 53, installs nginx; CI runners only)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Ubuntu's systemd-resolved stub holds 127.0.0.53:53; a Raspberry Pi OS host
# has nothing on port 53.
if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' >/etc/systemd/resolved.conf.d/rpi-setup-ci.conf
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

IFACE="$(ip -o route show default | awk '{print $5; exit}')"
COMPOSE=/opt/pihole/docker-compose.yml
setup_pihole() { env PIHOLE_INTERFACE="$IFACE" "$@" bash "$ROOT/setup.sh" pihole; }
setup_web() { env WEB_DOCKER=no "$@" bash "$ROOT/setup.sh" web; }
page() { curl -fsS --max-time 5 "http://127.0.0.1:${1}/${2:-}" 2>/dev/null || true; }
# auth PORT: Pi-hole's answer to a login with the saved password ('"valid":true').
auth() {
    local pw
    pw="$(sed -nE 's/^PIHOLE_PASSWORD=//p' /var/lib/rpi-setup/secrets/pihole.env)"
    curl -fsS --max-time 5 -X POST "http://127.0.0.1:$1/api/auth" -d "{\"password\":\"$pw\"}" 2>/dev/null || true
}
started() { docker inspect -f '{{.State.StartedAt}}' pihole 2>/dev/null || true; }
# wait_healthy: the container recreated by the move needs a moment.
wait_healthy() {
    local i
    for i in $(seq 1 60); do
        [[ "$(docker inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null)" == healthy ]] && return 0
        sleep 2
    done
    return 1
}

# nginx from an earlier run would keep Pi-hole off port 80; the web task
# starts it again below.
systemctl stop nginx 2>/dev/null || true

# Pi-hole on port 80, as on a Pi where it was set up before the web task
# (PIHOLE_WEB_PORT=80 overrides the port an earlier run of this suite left).
setup_pihole PIHOLE_DOCKER=yes PIHOLE_WEB_PORT=80
assert_ok "Pi-hole's container is healthy on port 80" wait_healthy
assert_contains "the admin page answers on port 80" '"valid":true' "$(auth 80)"

# WEB_PORT=80 is the default; it is passed so that an nginx an earlier run
# left on another port moves back and the run does not depend on that.
out="$(setup_web WEB_PORT=80 2>&1)"
echo "$out"
assert_contains "the web task moves Pi-hole off port 80" "Moving Pi-hole's web admin from port 80 to 8080" "$out"
assert_contains "and says where the admin page is now" "Pi-hole web admin moved to" "$out"
assert_contains "the compose file now names port 8080" 'FTLCONF_webserver_port: "8080o,443os,[::]:8080o,[::]:443os"' "$(cat "$COMPOSE")"
assert_ok "Pi-hole's container is healthy on port 8080" wait_healthy
assert_contains "the admin page answers on port 8080" '"valid":true' "$(auth 8080)"
assert_contains "DNS still answers on port 53" "127.0.0.1" "$(dig +short +time=3 @127.0.0.1 pi.hole 2>/dev/null || true)"
assert_ok "native nginx runs" systemctl is-active --quiet nginx
assert_contains "the start page answers on port 80" "rpi-setup" "$(page 80)"
assert_lacks "Pi-hole no longer answers on port 80" '"session"' "$(page 80 api/auth)"
assert_contains "the service list links Pi-hole" '"name":"Pi-hole"' "$(page 80 services.json)"
assert_contains "at port 8080" '"port":8080' "$(page 80 services.json)"

before="$(started)"
out="$(setup_web WEB_PORT=80 2>&1)"
assert_lacks "a web re-run moves nothing" "Moving Pi-hole" "$out"
assert_eq "a web re-run leaves the Pi-hole container alone" "$before" "$(started)"
assert_contains "the start page still answers on port 80" "rpi-setup" "$(page 80)"

setup_pihole PIHOLE_DOCKER=yes
assert_eq "a Pi-hole re-run keeps port 8080 and the container" "$before" "$(started)"
assert_contains "the admin page still answers on port 8080" '"valid":true' "$(auth 8080)"

finish_tests
