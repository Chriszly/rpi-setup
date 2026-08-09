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

  cat >"$compose" <<EOF
services:
  netalertx:
    image: "jokai-sk/netalertx:latest"
    container_name: $name
    network_mode: host
    read_only: true
    restart: unless-stopped
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
      GRAPHQL_PORT: 20212
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

  local subnet_cfg i conf="$dir/data/config/app.conf"
  for i in {1..20}; do [[ -f "$conf" ]] && break; sleep 1; done
  if subnet_cfg="$(detect_subnet)"; then
    configure_subnet "$conf" "$subnet_cfg"
  else
    warn "Could not auto-detect LAN subnet; set SCAN_SUBNETS in the UI (Settings > Subnets & Rules)"
  fi

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  say "NetAlertX dashboard: http://${ip:-<pi-ip>}:20211"
  say "Give it a minute to run its first ARP scan, then check the Devices page."
}

# Detect the LAN CIDR + interface from the default route, e.g. "192.168.1.50/24 --interface=eth0".
detect_subnet() {
  local iface cidr
  iface="$(ip route show default 2>/dev/null | awk '
    /^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$iface" ]] || return 1
  cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "$cidr" ]] || return 1
  printf '%s --interface=%s' "$cidr" "$iface"
}

# Patch SCAN_SUBNETS in NetAlertX's app.conf with the auto-detected value.
configure_subnet() {
  local conf="$1" cfg="$2"
  install -m 0755 -d "$(dirname "$conf")"
  [[ -f "$conf" ]] || return 0
  if grep -q '^SCAN_SUBNETS' "$conf"; then
    sed -i "s#^SCAN_SUBNETS.*#SCAN_SUBNETS = ['$cfg']#" "$conf"
  else
    printf "\nSCAN_SUBNETS = ['%s']\n" "$cfg" >>"$conf"
  fi
  say "Configured SCAN_SUBNETS = ['$cfg']"
}
