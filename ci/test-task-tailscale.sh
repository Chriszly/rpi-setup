#!/usr/bin/env bash
# test-task-tailscale.sh - unit tests for the flag building in tasks/tailscale.sh.
#
# Run: bash ci/test-task-tailscale.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/tailscale.sh"

# Print the flags tailscale_options builds for the current settings.
opts_for() {
  local -a o=()
  tailscale_options o
  printf '%s\n' "${o[*]:-}"
}

unset TAILSCALE_HOSTNAME TAILSCALE_SSH TAILSCALE_ADVERTISE_EXIT_NODE TAILSCALE_ADVERTISE_ROUTES TAILSCALE_ACCEPT_DNS

# --- accept-dns ----------------------------------------------------------------
tailscale_pihole_here() { return 1; }
assert_eq "no Pi-hole, no setting: no DNS flag" "" "$(opts_for)"
assert_eq "TAILSCALE_ACCEPT_DNS=no" "--accept-dns=false" "$(TAILSCALE_ACCEPT_DNS=no opts_for)"
assert_eq "TAILSCALE_ACCEPT_DNS=yes" "--accept-dns=true" "$(TAILSCALE_ACCEPT_DNS=yes opts_for)"
assert_fails "TAILSCALE_ACCEPT_DNS=maybe dies" env TAILSCALE_ACCEPT_DNS=maybe bash -c \
  ". '$ROOT/lib/common.sh'; TASKS=(); . '$ROOT/tasks/tailscale.sh'; o=(); tailscale_options o"

tailscale_pihole_here() { return 0; }
assert_eq "Pi-hole here: DNS off by default" "--accept-dns=false" "$(opts_for)"
assert_eq "Pi-hole here, explicit yes wins" "--accept-dns=true" "$(TAILSCALE_ACCEPT_DNS=yes opts_for)"

# --- existing flags still combine ------------------------------------------------
tailscale_pihole_here() { return 1; }
assert_eq "hostname and ssh" "--hostname=homepi --ssh=true" \
  "$(TAILSCALE_HOSTNAME=homepi TAILSCALE_SSH=yes opts_for)"
assert_eq "routes after dns flag" "--accept-dns=false --advertise-routes=192.168.1.0/24" \
  "$(TAILSCALE_ACCEPT_DNS=no TAILSCALE_ADVERTISE_ROUTES='192.168.1.0/24' opts_for)"

finish_tests
