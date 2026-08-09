#!/usr/bin/env bash
# Task: netalertx - LAN device presence tracking via NetAlertX (Docker).
set -euo pipefail

TASKS+=("netalertx|LAN device presence tracking (web UI :20211)")

run_netalertx() {
  command -v docker >/dev/null 2>&1 || die 'Docker is required. Run first: sudo bash setup.sh docker'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose is required. Run first: sudo bash setup.sh docker'

  local dir=/opt/netalertx
  local compose="$dir/docker-compose.yml"
  local name=netalertx

  if docker ps -q --filter "name=^${name}\$" >/dev/null 2>&1; then
    say "NetAlertX is already running. Dashboard: http://$(hostname -I 2>/dev/null | awk '{print $1}'):20211"
    return
  fi

  install -m 0755 -d "$dir"
  install -m 0755 -d "$dir/data"
  chown 20211:20211 "$dir/data"

  local subnet_cfg conf_override=""
  if subnet_cfg="$(detect_subnet)"; then
    say "Detected LAN subnet: $subnet_cfg"
    # Applied by NetAlertX at container start; survives restarts and avoids
    # racing the config watcher with a post-start app.conf edit.
    conf_override="APP_CONF_OVERRIDE: \"{\\\"SCAN_SUBNETS\\\":\\\"['${subnet_cfg}']\\\"}\""
  else
    warn "Could not auto-detect LAN subnet; set SCAN_SUBNETS in the UI (Settings > Subnets & Rules)"
  fi

  cat >"$compose" <<EOF
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
      - "/tmp:mode=1700,uid=20211,gid=20211,rw,noexec,nosuid,nodev,async,noatime,nodiratime"
    environment:
      PUID: 20211
      PGID: 20211
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
  docker compose -f "$compose" up -d --pull

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  say "NetAlertX dashboard: http://${ip:-<pi-ip>}:20211"
  say "Give it a few minutes to run its first ARP scan. Initial discovery can take 5-10 minutes."
}

# Detect the LAN network + interface from the default route, e.g. "192.168.1.0/24 --interface=eth0".
detect_subnet() {
  local iface ifip cidr
  iface="$(ip route show default 2>/dev/null | awk '
    /^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$iface" ]] || return 1
  ifip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "$ifip" ]] || return 1
  cidr="$(net_base "$ifip")" || return 1
  printf '%s --interface=%s' "$cidr" "$iface"
}

# Convert an "ip/prefix" to its network address, e.g. "192.168.1.50/24" -> "192.168.1.0/24".
net_base() {
  local cidr="$1" ip="${1%/*}" prefix="${1##*/}" net
  net="$(awk -v ip="$ip" -v p="$prefix" 'BEGIN {
    split(ip, a, ".");
    val = a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4];
    step = 2 ^ (32 - p);
    net = val - (int(val) % step);
    printf "%d.%d.%d.%d/%d\n",
      int(net / 16777216) % 256, int(net / 65536) % 256,
      int(net / 256) % 256, net % 256, p;
  }')" || return 1
  printf '%s\n' "$net"
}
