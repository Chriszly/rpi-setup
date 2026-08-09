#!/usr/bin/env bash
# Task: monitoring - Netdata for real-time system dashboards.
set -euo pipefail

TASKS+=("monitoring|Netdata monitoring dashboard (web UI :19999)")

run_monitoring() {
  if apt_installed netdata && systemctl is-active --quiet netdata; then
    say 'Netdata is already running'
    return
  fi
  apt_install netdata
  systemctl enable --now netdata
  say "Netdata dashboard: http://$(hostname):19999"
}