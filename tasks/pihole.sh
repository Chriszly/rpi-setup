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
  if [[ "${PIHOLE_CONFIRM:-}" != "yes" ]] && [[ -t 0 ]]; then
    local ans=""
    read -r -p 'Type "yes" to continue, anything else to skip: ' ans || { warn 'Skipped Pi-hole install.'; return; }
    [[ "$ans" == "yes" ]] || { warn 'Skipped Pi-hole install.'; return; }
  fi

  if [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; then
    info 'Running Pi-hole installer in unattended mode for container environment'
    export PIHOLE_SKIP_OS_CHECK=1
    export PIHOLE_INTERFACE="${PIHOLE_INTERFACE:-eth0}"
    export IPV4_ADDRESS="${IPV4_ADDRESS:-}"
    export IPV6_ADDRESS="${IPV6_ADDRESS:-}"
    export PIHOLE_DNS_1="${PIHOLE_DNS_1:-1.1.1.1}"
    export PIHOLE_DNS_2="${PIHOLE_DNS_2:-1.0.0.1}"
    export QUERY_LOGGING="${QUERY_LOGGING:-true}"
    export INSTALL_WEB_INTERFACE="${INSTALL_WEB_INTERFACE:-true}"
    export INSTALL_WEB_SERVER="${INSTALL_WEB_SERVER:-true}"
    export LIGHTTPD_ENABLED="${LIGHTTPD_ENABLED:-true}"
    export BLOCKING_ENABLED="${BLOCKING_ENABLED:-true}"
    export PIHOLE_SKIP_STATIC_IP=1
    export PIHOLE_STATIC_IPV4=""
    export PIHOLE_STATIC_IPV6=""
    curl -fsSL https://install.pi-hole.net | RUN_INSTALLER=true bash -s -- --unattended
  else
    info 'Running the official Pi-hole installer - follow its on-screen prompts'
    curl -fsSL https://install.pi-hole.net | bash
  fi

  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole installed - web admin: http://$(hostname)/admin"
  else
    warn 'Pi-hole installer did not complete'
  fi
}
