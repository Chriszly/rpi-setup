#!/usr/bin/env bash
# Task: monitoring - Netdata for real-time system dashboards.
set -euo pipefail

TASKS+=("monitoring|Netdata monitoring dashboard (web UI :19999)")

run_monitoring() {
  if ! apt_installed netdata; then
    apt_install netdata
  fi

  # Debian's netdata package only listens on 127.0.0.1, so the dashboard would
  # be unreachable from other machines. Open it to the LAN (idempotent).
  local conf=/etc/netdata/netdata.conf changed=0
  if netdata_listen_on_lan "$conf"; then
    changed=1
    info "Netdata now listens on all interfaces ($conf)"
  fi

  systemctl enable --now netdata
  if [[ $changed -eq 1 ]]; then
    systemctl restart netdata
  fi

  local ip=""
  ip="$(pi_ip)" || true
  say "Netdata dashboard: http://${ip:-$(hostname)}:19999"
}

# Rewrite a localhost-only bind in netdata.conf to 0.0.0.0. Returns 0 if the
# file was changed, 1 if there was nothing to change.
netdata_listen_on_lan() {
  local conf="$1"
  local re='^([[:space:]]*(bind socket to IP|bind to)[[:space:]]*=[[:space:]]*)(127\.0\.0\.1|localhost)[[:space:]]*$'
  if [[ ! -f "$conf" ]] || ! grep -Eq "$re" "$conf"; then return 1; fi
  sed -Ei "s/$re/\\10.0.0.0/" "$conf"
}
