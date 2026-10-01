#!/usr/bin/env bash
# Task: tailscale - WireGuard mesh VPN via the official install script.
# Settings: TAILSCALE_* in config/rpi-setup.env (names in config/tasks/tailscale.env).
set -euo pipefail

TASKS+=("tailscale|Tailscale VPN (official install script)")

run_tailscale() {
  local -a opts=()
  tailscale_options opts

  if ! command -v tailscale >/dev/null 2>&1; then
    warn 'The Tailscale installer uses "curl ... | sh"; review https://tailscale.com/install.sh if in doubt.'
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    say 'tailscale binary already present'
  fi

  systemctl enable --now tailscaled
  tailscale_forwarding

  # "tailscale status" exits non-zero until this node is logged in. (The
  # tailscale0 interface is not a signal: tailscaled creates it logged out too.)
  if tailscale status >/dev/null 2>&1; then
    say 'Tailscale is already up'
    if [[ ${#opts[@]} -gt 0 ]]; then
      info "Applying settings: ${opts[*]}"
      tailscale set "${opts[@]}" || die 'tailscale set failed; check the TAILSCALE_* settings'
    fi
  elif [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    info 'Logging in to Tailscale with TAILSCALE_AUTHKEY'
    tailscale up --authkey "$TAILSCALE_AUTHKEY" "${opts[@]}" || die 'tailscale up failed with the given auth key'
  else
    info 'Running "tailscale up" - open the printed URL to log this Pi in to your tailnet'
    tailscale up "${opts[@]}" || warn 'Login not completed; run "sudo tailscale up" later to finish.'
  fi
  tailscale status || true
}

# Fill array $1 with the "tailscale up/set" flags for the settings that are
# set. An empty setting adds no flag, so a re-run never undoes something
# configured by hand with "tailscale set".
tailscale_options() {
  local -n _ts_opts="$1"
  local routes="${TAILSCALE_ADVERTISE_ROUTES:-}" r
  if [[ -n "${TAILSCALE_HOSTNAME:-}" ]]; then
    valid_hostname "$TAILSCALE_HOSTNAME" || die "TAILSCALE_HOSTNAME must be letters, digits and '-' (got '$TAILSCALE_HOSTNAME')"
    _ts_opts+=("--hostname=$TAILSCALE_HOSTNAME")
  fi
  if [[ -n "${TAILSCALE_SSH:-}" ]]; then
    if setting_on TAILSCALE_SSH; then _ts_opts+=(--ssh=true); else _ts_opts+=(--ssh=false); fi
  fi
  if [[ -n "${TAILSCALE_ADVERTISE_EXIT_NODE:-}" ]]; then
    if setting_on TAILSCALE_ADVERTISE_EXIT_NODE; then _ts_opts+=(--advertise-exit-node=true); else _ts_opts+=(--advertise-exit-node=false); fi
  fi
  # A Pi running Pi-hole is the DNS server: taking the tailnet's DNS settings
  # (MagicDNS, or a global nameserver pointing at this Pi) would make it
  # resolve through itself. So "auto" (empty) turns it off when Pi-hole is here.
  if [[ -n "${TAILSCALE_ACCEPT_DNS:-}" ]]; then
    if setting_on TAILSCALE_ACCEPT_DNS; then _ts_opts+=(--accept-dns=true); else _ts_opts+=(--accept-dns=false); fi
  elif tailscale_pihole_here; then
    _ts_opts+=(--accept-dns=false)
  fi
  if [[ -n "$routes" ]]; then
    routes="${routes// /}"
    for r in ${routes//,/ }; do
      [[ "$r" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ || "$r" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] ||
        die "TAILSCALE_ADVERTISE_ROUTES: '$r' is not a subnet like 192.168.1.0/24"
    done
    _ts_opts+=("--advertise-routes=$routes")
  fi
}

# True if Pi-hole is installed on this Pi, natively or in its container.
tailscale_pihole_here() { command -v pihole >/dev/null 2>&1 || task_in_container pihole; }

# Subnet routes and exit nodes need IP forwarding.
tailscale_forwarding() {
  local f=/etc/sysctl.d/99-tailscale.conf
  if [[ -n "${TAILSCALE_ADVERTISE_ROUTES:-}" ]] ||
     { [[ -n "${TAILSCALE_ADVERTISE_EXIT_NODE:-}" ]] && setting_on TAILSCALE_ADVERTISE_EXIT_NODE; }; then
    if printf '%s\n' '# Managed by rpi-setup (tasks/tailscale.sh): routing for subnet routes / exit node.' \
        'net.ipv4.ip_forward = 1' 'net.ipv6.conf.all.forwarding = 1' | write_if_changed "$f" 0644; then
      sysctl -q -p "$f" || warn "Could not apply $f (applied on next boot)"
      say 'Enabled IP forwarding for Tailscale routing'
    fi
  fi
}

