#!/usr/bin/env bash
# Task: tailscale - WireGuard mesh VPN via the official install script.
set -euo pipefail

TASKS+=("tailscale|Tailscale VPN (official install script)")

run_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    say 'tailscale binary already present'
  fi

  systemctl enable --now tailscaled

  if ip link show tailscale0 >/dev/null 2>&1; then
    say 'Tailscale is already up'
  else
    info 'Running "tailscale up" - authenticate at the printed URL to finish login'
    tailscale up || warn 'Login not completed'
  fi
  tailscale status
}