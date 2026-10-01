#!/usr/bin/env bash
# smoke-container-pihole.sh - PIHOLE_DOCKER end to end on a runner with Docker
# and systemd: a fresh container answers DNS on port 53 with a generated
# password, native data in /etc/pihole is copied once, a re-run changes
# nothing and PIHOLE_LISTEN_ALL is applied. (The native installer is not run
# here: it does not support the Ubuntu runner.)
#
# Run: sudo bash ci/smoke-container-pihole.sh   (frees port 53; CI runners only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"

# Ubuntu's systemd-resolved stub holds 127.0.0.53:53; a Raspberry Pi OS host
# has nothing on port 53.
if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' >/etc/systemd/resolved.conf.d/rpi-setup-ci.conf
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

PORT=8085
IFACE="$(ip -o route show default | awk '{print $5; exit}')"
setup() { env PIHOLE_INTERFACE="$IFACE" PIHOLE_WEB_PORT=$PORT "$@" bash "$ROOT/setup.sh" pihole; }
started() { docker inspect -f '{{.State.StartedAt}}' pihole 2>/dev/null || true; }

# Stand-in for a native install's data: it must reach the container once.
mkdir -p /etc/pihole
echo native >/etc/pihole/rpi-setup-ci-marker

out="$(setup PIHOLE_DOCKER=yes 2>&1)"
echo "$out"
assert_contains "a password is generated and printed" "Generated web admin password:" "$out"
pw="$(sed -nE 's/^PIHOLE_PASSWORD=//p' /var/lib/rpi-setup/secrets/pihole.env)"
assert_eq "the container is healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null)"
assert_eq "the native data was copied" "native" "$(cat /opt/pihole/etc-pihole/rpi-setup-ci-marker 2>/dev/null)"
assert_contains "DNS answers on port 53" "127.0.0.1" "$(dig +short +time=3 @127.0.0.1 pi.hole 2>/dev/null || true)"
assert_contains "the admin password works" '"valid":true' \
    "$(curl -fsS --max-time 5 -X POST "http://127.0.0.1:$PORT/api/auth" -d "{\"password\":\"$pw\"}" 2>/dev/null || true)"
assert_eq "secrets.env is root-only" "600" "$(stat -c %a /opt/pihole/secrets.env)"
assert_eq "the password is not in the compose file" "" "$(grep -F "$pw" /opt/pihole/docker-compose.yml || true)"

before="$(started)"
echo changed >/etc/pihole/rpi-setup-ci-marker
out="$(setup PIHOLE_DOCKER=yes 2>&1)"
assert_eq "a re-run leaves the running container alone" "$before" "$(started)"
assert_eq "a re-run generates no new password" "" "$(grep 'Generated' <<<"$out" || true)"
assert_eq "native data is copied only once" "native" "$(cat /opt/pihole/etc-pihole/rpi-setup-ci-marker)"

setup PIHOLE_DOCKER=yes PIHOLE_LISTEN_ALL=yes
assert_eq "PIHOLE_LISTEN_ALL=yes reaches Pi-hole" "ALL" "$(docker exec pihole pihole-FTL --config dns.listeningMode 2>/dev/null)"

rm -rf /etc/pihole
finish_tests
