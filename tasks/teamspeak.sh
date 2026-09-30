#!/usr/bin/env bash
# Task: teamspeak - TeamSpeak 6 voice chat server (official Docker image, native arm64).
# Settings: TEAMSPEAK_* in config/rpi-setup.env (names in config/tasks/teamspeak.env).
set -euo pipefail

TASKS+=("teamspeak|TeamSpeak 6 voice server (voice :9987, file :30033, web :10080)")

run_teamspeak() {
  : "${TEAMSPEAK_VOICE_PORT:=9987}" "${TEAMSPEAK_FILE_PORT:=30033}" "${TEAMSPEAK_QUERY_PORT:=10080}"
  : "${TEAMSPEAK_QUERY_HTTP:=yes}" "${TEAMSPEAK_ACCEPT_LICENSE:=yes}"
  : "${TEAMSPEAK_IMAGE:=teamspeaksystems/teamspeak6-server:latest}"
  require_port TEAMSPEAK_VOICE_PORT
  require_port TEAMSPEAK_FILE_PORT
  require_port TEAMSPEAK_QUERY_PORT
  require_image_ref TEAMSPEAK_IMAGE
  local query="" admin_pw="${TEAMSPEAK_QUERY_ADMIN_PASSWORD:-}"
  # A set TSSERVER_QUERY_HTTP_ENABLED may count as "on" whatever its value,
  # so "no" leaves the variable out instead of setting it to false.
  if setting_on TEAMSPEAK_QUERY_HTTP; then
    query='      TSSERVER_QUERY_HTTP_ENABLED: "true"'
  fi
  setting_on TEAMSPEAK_ACCEPT_LICENSE ||
    die 'The TeamSpeak server only starts once you accept its license; set TEAMSPEAK_ACCEPT_LICENSE=yes'
  [[ "$admin_pw" != *[\"\\\$]* ]] ||
    die 'TEAMSPEAK_QUERY_ADMIN_PASSWORD cannot contain ", \ or $'

  # The official image is published for amd64 and arm64 only, so a Pi on a
  # 32-bit OS (armhf) cannot run it.
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == arm64 || "$arch" == amd64 ]] ||
    die "The TeamSpeak 6 image needs a 64-bit OS (this one is $arch). Flash Raspberry Pi OS Lite (64-bit)."

  require_docker

  local dir=/opt/teamspeak
  local name=teamspeak
  local ip=""

  # The official image runs as uid:gid 9987 and ignores PUID/PGID, so the data
  # directory must stay owned by 9987 for the bind mount to be writable.
  ensure_container_dir "$dir" 9987

  # The container listens on the same ports it publishes: TeamSpeak tells
  # clients which file transfer port to use, so the two must match. The
  # compose file holds the query password, hence root-only (0600).
  local changed=0
  if write_if_changed "$dir/docker-compose.yml" 0600 <<EOF
services:
  teamspeak:
    image: "$TEAMSPEAK_IMAGE"
    container_name: $name
    restart: unless-stopped
    ports:
      - "${TEAMSPEAK_VOICE_PORT}:${TEAMSPEAK_VOICE_PORT}/udp"   # Voice
      - "${TEAMSPEAK_FILE_PORT}:${TEAMSPEAK_FILE_PORT}/tcp"     # File transfer
      - "${TEAMSPEAK_QUERY_PORT}:${TEAMSPEAK_QUERY_PORT}/tcp"   # Web query
    environment:
      TSSERVER_LICENSE_ACCEPTED: "accept"
      TSSERVER_DEFAULT_PORT: "${TEAMSPEAK_VOICE_PORT}"
      TSSERVER_FILE_TRANSFER_PORT: "${TEAMSPEAK_FILE_PORT}"
      TSSERVER_QUERY_HTTP_PORT: "${TEAMSPEAK_QUERY_PORT}"
${query}
$(if [[ -n "$admin_pw" ]]; then printf '      TSSERVER_QUERY_ADMIN_PASSWORD: "%s"\n' "$admin_pw"; fi)
    volumes:
      - type: bind
        source: $dir/data
        target: /var/tsserver
EOF
  then
    changed=1
  fi

  if [[ $changed -eq 0 ]] && compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "TeamSpeak 6 is already running with these settings. Connect to ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT}"
    return
  fi

  # The privilege key is only printed when the server creates its database.
  local fresh=0 token=""
  [[ -n "$(ls -A "$dir/data" 2>/dev/null)" ]] || fresh=1

  say 'Starting TeamSpeak 6 container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  if [[ $fresh -eq 0 ]]; then
    say "TeamSpeak 6 restarted with the new settings at ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT}"
    return
  fi
  token="$(wait_for_log "$name" 'privilege key')"

  say "TeamSpeak 6 server ready at ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT} (file transfer :${TEAMSPEAK_FILE_PORT}, web query :${TEAMSPEAK_QUERY_PORT})"
  if [[ -n "$token" ]]; then
    say "ServerAdmin privilege key (needed for first login, shown only once):"
    printf '  %s\n' "$token"
  else
    warn "Could not spot the ServerAdmin privilege key in the logs yet."
    say "Find it later with: docker logs $name"
  fi
  say "Connect with the TeamSpeak 6 client and enter the privilege key when asked."
  if [[ "$TEAMSPEAK_VOICE_PORT" != 9987 ]]; then
    info 'TEAMSPEAK_VOICE_PORT only takes effect for a new server (empty data directory).'
  fi
}
