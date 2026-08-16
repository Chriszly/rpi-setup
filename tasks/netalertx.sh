#!/usr/bin/env bash
# Task: netalertx - LAN device presence tracking via NetAlertX (Docker).
set -euo pipefail

TASKS+=("netalertx|LAN device presence tracking (web UI :20211)")

run_netalertx() {
  require_docker

  local dir=/opt/netalertx
  local name=netalertx
  local ip=""

  if compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "NetAlertX is already running. Dashboard: http://${ip:-<pi-ip>}:20211"
    return
  fi

  local uid
  uid="$(assign_uid netalertx)"
  ensure_container_dir "$dir" "$uid"

  local subnet_cfg conf_override=""
  if subnet_cfg="$(detect_subnet)"; then
    say "Detected LAN subnet: $subnet_cfg"
    # Applied by NetAlertX at container start; survives restarts and avoids
    # racing the config watcher with a post-start app.conf edit.
    conf_override="APP_CONF_OVERRIDE: \"{\\\"SCAN_SUBNETS\\\":\\\"['${subnet_cfg}']\\\"}\""
  else
    warn "Could not auto-detect LAN subnet; set SCAN_SUBNETS in the UI (Settings > Subnets & Rules)"
  fi

  cat >"$dir/docker-compose.yml" <<EOF
services:
  netalertx:
    image: "ghcr.io/netalertx/netalertx:latest"
    container_name: $name
    network_mode: host
    read_only: true
    restart: unless-stopped
    pids_limit: 512
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
    sysctls:
      net.ipv4.conf.all.arp_ignore: 1
      net.ipv4.conf.all.arp_announce: 2
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,noexec,nosuid,nodev,async,noatime,nodiratime"
    environment:
      PUID: $uid
      PGID: $uid
      LISTEN_ADDR: 0.0.0.0
      PORT: 20211
      $conf_override
    volumes:
      - type: bind
        source: $dir/data
        target: /data
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
EOF

  say 'Starting NetAlertX container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "NetAlertX dashboard: http://${ip:-<pi-ip>}:20211"
  say "Give it a few minutes to run its first ARP scan. Initial discovery can take 5-10 minutes."
}
