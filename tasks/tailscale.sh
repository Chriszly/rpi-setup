#!/usr/bin/env bash
# Task: tailscale - WireGuard mesh VPN via the official Docker image.
set -euo pipefail

TASKS+=("tailscale|Tailscale VPN (container; authenticate via printed URL)")

run_tailscale() {
  require_docker

  local dir=/opt/tailscale
  local name=tailscale

  [[ -c /dev/net/tun ]] || die 'Missing /dev/net/tun - load it with: sudo modprobe tun'

  if compose_is_up "$name"; then
    say 'Tailscale container is already running. Status:'
    docker exec "$name" tailscale status 2>/dev/null ||
      warn 'Not logged in yet - check: docker logs tailscale'
    return
  fi

  # Avoid clashing with a native tailscaled from an older run.
  if systemctl is-active --quiet tailscaled 2>/dev/null; then
    info 'Disabling native tailscaled so the container can take over'
    systemctl disable --now tailscaled >/dev/null 2>&1 || true
  fi

  local uid
  uid="$(assign_uid tailscale)"
  ensure_container_dir "$dir" "$uid"

  cat >"$dir/docker-compose.yml" <<EOF
services:
  tailscale:
    image: "ghcr.io/tailscale/tailscale:latest"
    container_name: $name
    hostname: $(hostname)
    restart: unless-stopped
    pids_limit: 256
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_add:
      - NET_ADMIN
    environment:
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
      TS_HOSTNAME: $(hostname)
    volumes:
      - type: bind
        source: $dir/data
        target: /var/lib/tailscale
      - type: bind
        source: /dev/net/tun
        target: /dev/net/tun
EOF

  say 'Starting Tailscale container'
  compose_up "$dir"

  info 'Waiting for the login URL (authenticate in your browser to finish setup)'
  local url
  url="$(wait_for_log "$name" 'login.tailscale.com' 60)"
  if [[ -n "$url" ]]; then
    printf '%s\n' "$url"
    say 'Open the URL above, log in, and approve this device.'
  else
    warn "Could not spot a login URL yet - run: docker logs $name"
  fi
}
