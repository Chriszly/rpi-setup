#!/usr/bin/env bash
# Task: usagecontrol - usage-control hardware usage website (Docker).
# Settings: USAGECONTROL_* in config/rpi-setup.env (names in config/tasks/usagecontrol.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("usagecontrol|usage-control: CPU, memory and temperature of the Pi in the browser (:8090)")

# usagecontrol_compose IMAGE PORT - the compose file: the host's /proc and /sys
# read-only (gopsutil reads them through HOST_PROC/HOST_SYS), the website on
# PORT, no capabilities and a read-only root file system.
usagecontrol_compose() {
  cat <<EOF2
services:
  usage-control:
    image: "$1"
    container_name: usage-control
    restart: unless-stopped
    ports:
      - "$2:8080"
    environment:
      HOST_PROC: /host/proc
      HOST_SYS: /host/sys
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
}

run_usagecontrol() {
  : "${USAGECONTROL_PORT:=8090}" "${USAGECONTROL_IMAGE:=ghcr.io/chriszly/usage-control:main}"
  require_port USAGECONTROL_PORT
  require_image_ref USAGECONTROL_IMAGE

  # The image is published for arm64 and amd64 only.
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == arm64 || "$arch" == amd64 ]] ||
    die "The usage-control image needs a 64-bit OS (this one is $arch). Flash Raspberry Pi OS Lite (64-bit)."

  # The port may already be ours (Docker's proxy); anything else holds it.
  local owner
  owner="$(port_owner "$USAGECONTROL_PORT")" || owner=""
  if [[ -n "$owner" && "$owner" != docker-proxy ]]; then
    die "Port $USAGECONTROL_PORT is used by $owner; set USAGECONTROL_PORT to a free port"
  fi

  container_require_docker

  local dir name=usage-control changed=0
  dir="$(container_dir usagecontrol)"
  install -m 0755 -d "$dir"
  if usagecontrol_compose "$USAGECONTROL_IMAGE" "$USAGECONTROL_PORT" | write_if_changed "$dir/docker-compose.yml" 0644; then
    changed=1
  fi

  container_pull "$dir"
  container_up "$dir" "$name"

  if [[ $changed -eq 1 ]]; then
    say "usage-control is running with the new settings: $(service_url "$USAGECONTROL_PORT")"
  else
    say "usage-control is running: $(service_url "$USAGECONTROL_PORT")"
  fi
}
