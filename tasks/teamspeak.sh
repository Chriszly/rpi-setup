#!/usr/bin/env bash
# Task: teamspeak - TeamSpeak 6 voice chat server (official Docker image, native arm64).
set -euo pipefail

TASKS+=("teamspeak|TeamSpeak 6 voice server (voice :9987, file :30033, web :10080)")

run_teamspeak() {
  command -v docker >/dev/null 2>&1 || die 'Docker is required. Run first: sudo bash setup.sh docker'

  local dir=/opt/teamspeak
  local compose="$dir/docker-compose.yml"
  local name=teamspeak

  if docker ps -q --filter "name=^${name}\$" >/dev/null 2>&1; then
    say "TeamSpeak 6 is already running. Connect to $(hostname -I 2>/dev/null | awk '{print $1}'):9987"
    return
  fi

  install -m 0755 -d "$dir"
  install -m 0755 -d "$dir/data"
  chown 9987:9987 "$dir/data"

  cat >"$compose" <<EOF
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
  docker compose -f "$compose" up -d --pull

  local ip token
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  token="$(wait_for_token "$name")"

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

# Wait for the first-run ServerAdmin privilege key in the container logs.
wait_for_token() {
  local name="$1" i key=""
  for i in {1..30}; do
    key="$(docker logs "$name" 2>&1 | grep -A1 -i 'privilege key' | tail -2)" || true
    [[ -n "$key" ]] && break
    sleep 1
  done
  printf '%s\n' "$key"
}
