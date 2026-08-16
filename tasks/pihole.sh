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
  if [[ "${PIHOLE_CONFIRM:-}" != "yes" ]]; then
    if [[ ! -t 0 ]]; then
      warn 'Non-interactive session detected; Pi-hole install skipped (set PIHOLE_CONFIRM=yes to override).'
      return
    fi
    local ans=""
    read -r -p 'Type "yes" to continue, anything else to skip: ' ans || { warn 'Skipped Pi-hole install.'; return; }
    [[ "$ans" == "yes" ]] || { warn 'Skipped Pi-hole install.'; return; }
  fi
  info 'Running the official Pi-hole installer - follow its on-screen prompts'
  curl -fsSL https://install.pi-hole.net | bash
  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole installed - web admin: http://$(hostname)/admin"
  else
    warn 'Pi-hole installer did not complete'
  fi
}
