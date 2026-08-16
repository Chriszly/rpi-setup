#!/usr/bin/env bash
# Task: pihole - network-wide ad blocking via the official installer.
set -euo pipefail

TASKS+=("pihole|Pi-hole ad blocker (official installer - interactive)")

run_pihole() {
  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole is already installed (run 'pihole -d' to debug)"
    return
  fi
  warn 'The Pi-hole installer uses "curl ... | bash" which has security implications.'
  warn 'Review the script at https://install.pi-hole.net before proceeding.'
  info 'Running the official Pi-hole installer - follow its on-screen prompts'
  curl -fsSL https://install.pi-hole.net | bash
  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole installed - web admin: http://$(hostname)/admin"
  else
    warn 'Pi-hole installer did not complete'
  fi
}