#!/usr/bin/env bash
# Task: tailscale - WireGuard mesh VPN via the official install script.
set -euo pipefail

TASKS+=("tailscale|Tailscale VPN (official install script)")

run_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    warn 'The Tailscale installer uses "curl ... | sh"; review https://tailscale.com/install.sh if in doubt.'
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    say 'tailscale binary already present'
  fi

  systemctl enable --now tailscaled

  # "tailscale status" exits non-zero until this node is logged in. (The
  # tailscale0 interface is not a signal: tailscaled creates it logged out too.)
  if tailscale status >/dev/null 2>&1; then
    say 'Tailscale is already up'
  elif [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    info 'Logging in to Tailscale with TAILSCALE_AUTHKEY'
    tailscale up --authkey "$TAILSCALE_AUTHKEY" || die 'tailscale up failed with the given auth key'
  else
    info 'Running "tailscale up" - open the printed URL to log this Pi in to your tailnet'
    tailscale up || warn 'Login not completed; run "sudo tailscale up" later to finish.'
  fi
  tailscale status || true
}
