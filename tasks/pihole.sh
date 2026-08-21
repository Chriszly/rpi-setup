#!/usr/bin/env bash
# Task: pihole - network-wide ad blocking via the official Docker image.
set -euo pipefail

TASKS+=("pihole|Pi-hole ad blocker (container, DNS :53, web UI :8080)")

run_pihole() {
  require_docker

  local dir=/opt/pihole
  local name=pihole
  local ip=""

  if compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "Pi-hole is already running. Web admin: http://${ip:-<pi-ip>}:8080/admin"
    return
  fi

  # Free port 53 in case a native Pi-hole from an older run is still active.
  if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    info 'Disabling native Pi-hole so the container can bind port 53'
    systemctl disable --now pihole-FTL >/dev/null 2>&1 || true
  fi

  local uid
  uid="$(assign_uid pihole)"
  ensure_container_dir "$dir" "$uid"

  # Web UI password: honour $PIHOLE_PASSWORD, otherwise generate a random one
  # once and persist it (never printed to the console).
  local pwfile="$dir/webpassword" pw=""
  if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
    pw="${PIHOLE_PASSWORD}"
    say 'Using web UI password from the PIHOLE_PASSWORD environment variable'
  elif [[ -r "$pwfile" ]] && [[ -s "$pwfile" ]]; then
    pw="$(<"$pwfile")"
    say "Using existing web UI password from $pwfile"
  else
    command -v openssl >/dev/null 2>&1 || apt_install openssl
    pw="$(openssl rand -base64 18 | tr '/+' '_-')"
    printf '%s\n' "$pw" >"$pwfile"
    chmod 600 "$pwfile"
    say "Generated a random web UI password and stored it in $pwfile"
  fi

  local tz=""
  tz="$(cat /etc/timezone 2>/dev/null || true)"

  # Escape the password for double-quoted YAML scalars.
  local pw_yaml="${pw//\\/\\\\}"
  pw_yaml="${pw_yaml//\"/\\\"}"

  cat >"$dir/docker-compose.yml" <<EOF
services:
  pihole:
    image: "pihole/pihole:latest"
    container_name: $name
    hostname: $(hostname)
    restart: unless-stopped
    pids_limit: 256
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
      - NET_ADMIN   # only needed when running the container as your DHCP server
      - SYS_NICE
    ports:
      - "53:53/tcp"     # DNS
      - "53:53/udp"     # DNS
      - "8080:80/tcp"   # Web admin UI
    environment:
      TZ: "${tz:-UTC}"
      FTLCONF_webserver_api_password: "$pw_yaml"
      FTLCONF_dns_listeningMode: "ALL"
    volumes:
      - type: bind
        source: $dir/data
        target: /etc/pihole
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
EOF

  say 'Starting Pi-hole container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "Pi-hole ready - point your devices' DNS at ${ip:-<pi-ip>}"
  say "Web admin: http://${ip:-<pi-ip>}:8080/admin"
}
