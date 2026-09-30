#!/usr/bin/env bash
# Task: netalertx - LAN device presence tracking via NetAlertX (Docker).
# Settings: NETALERTX_* in config/rpi-setup.env (names in config/tasks/netalertx.env).
set -euo pipefail

TASKS+=("netalertx|LAN device presence tracking (web UI :20211)")

run_netalertx() {
  : "${NETALERTX_PORT:=20211}" "${NETALERTX_IMAGE:=ghcr.io/netalertx/netalertx:latest}"
  require_port NETALERTX_PORT
  require_image_ref NETALERTX_IMAGE
  local subnets="${NETALERTX_SCAN_SUBNETS:-}"
  if [[ -n "$subnets" ]]; then
    # e.g. "192.168.1.0/24 --interface=eth0"; several separated by ";".
    [[ "$subnets" =~ ^[0-9./]+\ --interface=[A-Za-z0-9._-]+(\;[0-9./]+\ --interface=[A-Za-z0-9._-]+)*$ ]] ||
      die "NETALERTX_SCAN_SUBNETS must look like '192.168.1.0/24 --interface=eth0' (got '$subnets')"
  fi
  require_docker

  local dir=/opt/netalertx
  local name=netalertx
  local ip=""

  local uid
  uid="$(assign_uid netalertx)"
  ensure_container_dir "$dir" "$uid"

  local subnet_cfg="" conf_override="" s list=""
  local -a parts=()
  if [[ -n "$subnets" ]]; then
    subnet_cfg="$subnets"
    say "Scanning NETALERTX_SCAN_SUBNETS: $subnet_cfg"
  elif subnet_cfg="$(detect_subnet)"; then
    say "Detected LAN subnet: $subnet_cfg"
  else
    subnet_cfg=""
  fi
  if [[ -n "$subnet_cfg" ]]; then
    IFS=';' read -r -a parts <<<"$subnet_cfg"
    for s in "${parts[@]}"; do list+="${list:+,}'${s}'"; done
    # Applied by NetAlertX at container start; survives restarts and avoids
    # racing the config watcher with a post-start app.conf edit.
    conf_override="APP_CONF_OVERRIDE: \"{\\\"SCAN_SUBNETS\\\":\\\"[${list}]\\\"}\""
  else
    warn "Could not auto-detect LAN subnet; set SCAN_SUBNETS in the UI (Settings > Subnets & Rules)"
  fi

  # NetAlertX recommends arp_ignore=1 / arp_announce=2 to avoid ARP flux while
  # it scans. With network_mode: host the container shares the host's network
  # namespace, and runc refuses any net.* sysctl there ("not allowed in host
  # network namespace"), so they must be applied on the host instead.
  cat >/etc/sysctl.d/90-netalertx.conf <<'EOF'
# Managed by rpi-setup (tasks/netalertx.sh): ARP flux mitigation for NetAlertX.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF
  sysctl -q -p /etc/sysctl.d/90-netalertx.conf || warn 'Could not apply /etc/sysctl.d/90-netalertx.conf (applied on next boot)'

  local changed=0
  if write_if_changed "$dir/docker-compose.yml" 0644 <<EOF
services:
  netalertx:
    image: "$NETALERTX_IMAGE"
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
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,noexec,nosuid,nodev,async,noatime,nodiratime"
    environment:
      PUID: $uid
      PGID: $uid
      LISTEN_ADDR: 0.0.0.0
      PORT: $NETALERTX_PORT
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
  then
    changed=1
  fi

  if [[ $changed -eq 0 ]] && compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "NetAlertX is already running with these settings. Dashboard: http://${ip:-<pi-ip>}:${NETALERTX_PORT}"
    return
  fi

  say 'Starting NetAlertX container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "NetAlertX dashboard: http://${ip:-<pi-ip>}:${NETALERTX_PORT}"
  say "Give it a few minutes to run its first ARP scan. Initial discovery can take 5-10 minutes."
}
