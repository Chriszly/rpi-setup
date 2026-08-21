#!/usr/bin/env bash
# Task: monitoring - Netdata real-time system dashboards (official Docker image).
set -euo pipefail

TASKS+=("monitoring|Netdata monitoring dashboard (container, web UI :19999)")

run_monitoring() {
  require_docker

  local dir=/opt/monitoring
  local name=netdata
  local ip=""

  if compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "Netdata is already running: http://${ip:-<pi-ip>}:19999"
    return
  fi

  # Free port 19999 in case a native netdata from an older run is still active.
  if systemctl is-active --quiet netdata 2>/dev/null; then
    info 'Disabling native netdata so the container can bind port 19999'
    systemctl disable --now netdata >/dev/null 2>&1 || true
  fi

  local uid
  uid="$(assign_uid monitoring)"
  ensure_container_dir "$dir" "$uid"
  install -m 0755 -d "$dir/config" "$dir/lib" "$dir/cache"
  chown "$uid:$uid" "$dir/config" "$dir/lib" "$dir/cache"

  cat >"$dir/docker-compose.yml" <<EOF
services:
  netdata:
    image: "netdata/netdata:latest"
    container_name: $name
    hostname: $(hostname)
    network_mode: host
    restart: unless-stopped
    pids_limit: 512
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_add:
      - SYS_PTRACE
    volumes:
      - type: bind
        source: $dir/config
        target: /etc/netdata
      - type: bind
        source: $dir/lib
        target: /var/lib/netdata
      - type: bind
        source: $dir/cache
        target: /var/cache/netdata
      - type: bind
        source: /proc
        target: /host/proc
        read_only: true
      - type: bind
        source: /sys
        target: /host/sys
        read_only: true
      - type: bind
        source: /etc/passwd
        target: /host/etc/passwd
        read_only: true
      - type: bind
        source: /etc/group
        target: /host/etc/group
        read_only: true
      - type: bind
        source: /etc/os-release
        target: /host/etc/os-release
        read_only: true
      - type: bind
        source: /var/log
        target: /host/var/log
        read_only: true
EOF

  say 'Starting Netdata container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "Netdata dashboard: http://${ip:-<pi-ip>}:19999"
}
