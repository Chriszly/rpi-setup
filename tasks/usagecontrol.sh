#!/usr/bin/env bash
# Task: usagecontrol - usage-control hardware usage website (Docker).
# Settings: USAGECONTROL_* in config/rpi-setup.env (names in config/tasks/usagecontrol.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("usagecontrol|usage-control: CPU, memory and temperature of the Pi in the browser (:9393)")

# usagecontrol_compose IMAGE PORT [ROUTERS] - the compose file: the host's
# /proc and /sys read-only (gopsutil reads them through HOST_PROC/HOST_SYS),
# the website on PORT (the container listens on 9393), the routers to show
# (HUB_ROUTERS) with their passwords from router-secrets/, the history in a
# named volume, no capabilities and a read-only root file system.
usagecontrol_compose() {
  cat <<EOF2
services:
  usage-control:
    image: "$1"
    container_name: usage-control
    restart: unless-stopped
    ports:
      - "0.0.0.0:$2:9393"
    environment:
      PUBLIC_PORT: "$2"
      HOST_PROC: /host/proc
      HOST_SYS: /host/sys
      HUB_ROUTERS: "${3:-}"
      ROUTER_PASSWORDS_FILE: /run/secrets/router-passwords
    volumes:
      - data:/data
      - ./router-secrets:/run/secrets:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
volumes:
  data:
EOF2
}

run_usagecontrol() {
  : "${USAGECONTROL_PORT:=9393}" "${USAGECONTROL_IMAGE:=ghcr.io/chriszly/usage-control:main}" "${USAGECONTROL_ROUTER_PASSWORD:=}"
  require_port USAGECONTROL_PORT
  require_image_ref USAGECONTROL_IMAGE
  # usage-control checks each router itself; here only what could break the
  # compose file (quotes, $, backslashes, line breaks) is refused.
  local safe='^[][A-Za-z0-9 ._@:=,-]*$'
  [[ "${USAGECONTROL_ROUTERS:-}" =~ $safe ]] ||
    die "USAGECONTROL_ROUTERS must be name=protocol:address entries, such as Router=upnp:192.168.1.1, with only letters, digits, spaces and . _ @ : = , - [ ] (got '${USAGECONTROL_ROUTERS}')"

  # Router passwords: from USAGECONTROL_ROUTER_PASSWORD, kept for the next
  # runs, or the ones kept from an earlier run, so they never need to be in
  # the settings file.
  local passwords="$USAGECONTROL_ROUTER_PASSWORD" entry named='^ *[^= ][^=]*=.+$'
  if [[ -n "$passwords" ]]; then
    local -a entries
    [[ "$passwords" != *$'\n'* ]] || die "USAGECONTROL_ROUTER_PASSWORD must be on one line"
    IFS=, read -ra entries <<<"$passwords"
    for entry in "${entries[@]}"; do
      # The value is not shown, as it holds passwords.
      [[ "$entry" =~ $named ]] ||
        die "USAGECONTROL_ROUTER_PASSWORD must be name=password entries, comma-separated, such as Router=secret"
    done
  else
    passwords="$(load_secret usagecontrol USAGECONTROL_ROUTER_PASSWORD)" || passwords=""
  fi

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
  install -m 0755 -d "$dir" "$dir/router-secrets"
  if usagecontrol_compose "$USAGECONTROL_IMAGE" "$USAGECONTROL_PORT" "${USAGECONTROL_ROUTERS:-}" | write_if_changed "$dir/docker-compose.yml" 0644; then
    changed=1
  fi

  # The passwords file, one name=password per line, readable only by root
  # and the container's user. usage-control reads it at start, so a changed
  # file restarts the container.
  # 65532 is the image's non-root user (distroless nonroot).
  local secrets="$dir/router-secrets/router-passwords" recreate=0
  if [[ -n "$USAGECONTROL_ROUTER_PASSWORD" ]]; then
    save_secret usagecontrol USAGECONTROL_ROUTER_PASSWORD "$passwords"
  fi
  if [[ -n "$passwords" ]]; then
    if tr ',' '\n' <<<"$passwords" | write_if_changed "$secrets" 0400; then
      recreate=1
    fi
    chown 65532:65532 "$secrets"
  elif [[ -e "$secrets" ]]; then
    rm -f "$secrets"
    recreate=1
  fi
  [[ $recreate -eq 0 ]] || changed=1

  container_pull "$dir"
  container_up "$dir" "$name" "$recreate"

  if [[ $changed -eq 1 ]]; then
    say "usage-control is running with the new settings: $(service_url "$USAGECONTROL_PORT")"
  else
    say "usage-control is running: $(service_url "$USAGECONTROL_PORT")"
  fi
}
