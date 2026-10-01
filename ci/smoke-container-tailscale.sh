#!/usr/bin/env bash
# smoke-container-tailscale.sh - TAILSCALE_DOCKER end to end on a runner with
# Docker and systemd, without logging in to a tailnet: native tailscaled, the
# switch copies its state (so a logged-in Pi keeps its node) and the container
# offers a login URL, Tailscale SSH is refused, then back to native.
#
# Run: sudo bash ci/smoke-container-tailscale.sh   (installs tailscale; CI runners only)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

setup() { env "$@" bash "$ROOT/setup.sh" tailscale; }
# Native "tailscale up" waits for a login that never comes here; give it a minute.
native() { timeout 60 env TAILSCALE_DOCKER=no bash "$ROOT/setup.sh" tailscale </dev/null || true; }
started() { docker inspect -f '{{.State.StartedAt}}' tailscale 2>/dev/null || true; }

native
assert_ok "native tailscaled runs" systemctl is-active --quiet tailscaled

out="$(setup TAILSCALE_DOCKER=yes 2>&1)"
echo "$out"
assert_fails "native tailscaled is stopped" systemctl is-active --quiet tailscaled
assert_ok "the native state was copied" test -s /opt/tailscale/state/tailscaled.state
assert_eq "the container is running" "running" "$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null)"
assert_contains "the task prints a login URL" "https://login.tailscale.com/" "$out"
assert_ok "tailscale0 exists on the host" test -d /sys/class/net/tailscale0

assert_fails "TAILSCALE_SSH=yes is refused in a container" setup TAILSCALE_DOCKER=yes TAILSCALE_SSH=yes

native
assert_eq "switching back removes the container" "" "$(started)"
assert_ok "native tailscaled runs again" systemctl is-active --quiet tailscaled

finish_tests
