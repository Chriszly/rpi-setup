#!/usr/bin/env bash
# Task: teamspeak - TeamSpeak 6 voice chat server (official Docker image, native arm64).
set -euo pipefail

TASKS+=("teamspeak|TeamSpeak 6 voice server (voice :9987, file :30033, web :10080)")

run_teamspeak() {
  require_docker

  local dir=/opt/teamspeak
  local name=teamspeak

  if compose_is_up "$name"; then
    say "TeamSpeak 6 is already running. Connect to $(pi_ip):9987"
    return
  fi

  ensure_container_dir "$dir" 9987

  cat >"$dir/docker-compose.yml" <<EOF
services:
  teamspeak:
    image: "teamspeaksystems/teamspeak6-server:latest"
    container_name: $name
    restart: unless-stopped
    ports:
      - "9987:9987/udp"   # Voice
      - "30033:30033/tcp" # File transfer
      - "10080:10080/tcp" # Web query
    environment:
      TSSERVER_LICENSE_ACCEPTED: "accept"
      TSSERVER_QUERY_HTTP_ENABLED: "true"
    volumes:
      - type: bind
        source: $dir/data
        target: /var/tsserver
EOF

  say 'Starting TeamSpeak 6 container'
  compose_up "$dir"

  local ip token
  ip="$(pi_ip)"
  token="$(wait_for_log "$name" 'privilege key')"

  say "TeamSpeak 6 server ready at ${ip:-<pi-ip>}:9987 (file transfer :30033, web query :10080)"
  if [[ -n "$token" ]]; then
    say "ServerAdmin privilege key (needed for first login, shown only once):"
    printf '  %s\n' "$token"
  else
    warn "Could not spot the ServerAdmin privilege key in the logs yet."
    say "Find it later with: docker logs $name"
  fi
  say "Connect with the TeamSpeak 6 client and enter the privilege key when asked."
}
