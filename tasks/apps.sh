#!/usr/bin/env bash
# Task: apps - your own web apps from container images (Docker), such as a
# static site or a game built by your repository's CI.
# Settings: APPS_* in config/rpi-setup.env (names in config/tasks/apps.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("apps|Your own web apps from container images, each with a card on the start page")

# apps_parse LIST - check APPS_LIST and print one "name port container-port
# image" line per app. LIST holds name:port=image entries, or
# name:port:container-port=image when the app does not listen on 8080,
# separated by spaces or commas. Dies naming the entry that is wrong.
apps_parse() {
  local entry name ports image port cport names=" " used=" "
  local re='^([a-z0-9][a-z0-9-]{0,30}):([0-9]{1,5})(:([0-9]{1,5}))?=(.+)$'
  for entry in ${1//,/ }; do
    [[ "$entry" =~ $re ]] ||
      die "APPS_LIST entries must look like name:port=image, such as game:8091=ghcr.io/you/game:latest (got '$entry')"
    name="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" cport="${BASH_REMATCH[4]:-8080}" image="${BASH_REMATCH[5]}"
    for ports in "$port" "$cport"; do
      (( 10#$ports >= 1 && 10#$ports <= 65535 )) ||
        die "APPS_LIST: the ports of '$name' must be between 1 and 65535 (got '$entry')"
    done
    [[ "$image" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ ]] ||
      die "APPS_LIST: the image of '$name' must be a Docker image such as repo/name:tag (got '$image')"
    [[ "$names" != *" $name "* ]] || die "APPS_LIST names '$name' twice"
    [[ "$used" != *" $((10#$port)) "* ]] || die "APPS_LIST: port $port is used by two apps"
    names+="$name " used+="$((10#$port)) "
    printf '%s %s %s %s\n' "$name" "$((10#$port))" "$((10#$cport))" "$image"
  done
}

# apps_compose UID < "name port container-port image" lines - the compose
# file: one container per app, named after it, published on its port, with
# labels that give it a card on the web task's start page. Every app runs as
# UID (not root), with no capabilities, a read-only file system and only /tmp
# writable (in memory), so it keeps nothing between restarts.
apps_compose() {
  local uid="$1" name port cport image
  echo 'services:'
  while read -r name port cport image; do
    cat <<EOF2
  $name:
    image: "$image"
    container_name: $name
    restart: unless-stopped
    labels:
      rpi-setup.link.name: "$name"
      rpi-setup.link.description: "App from $image"
      rpi-setup.link.port: "$port"
    ports:
      - "0.0.0.0:$port:$cport"
    user: "$uid:$uid"
    read_only: true
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,nosuid,nodev,noexec"
    volumes:
      - /etc/localtime:/etc/localtime:ro
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
  done
}

run_apps() {
  local apps dir
  dir="$(container_dir apps)"
  apps="$(apps_parse "${APPS_LIST:-}")"
  if [[ -z "$apps" ]]; then
    # An emptied list takes the apps down; the compose file is renamed so
    # update.sh, the firewall and check.sh no longer see them.
    if [[ -f "$dir/docker-compose.yml" ]]; then
      docker compose -f "$dir/docker-compose.yml" down --remove-orphans ||
        die "Could not stop the apps in $dir; stop them with: cd $dir && sudo docker compose down"
      mv -f "$dir/docker-compose.yml" "$dir/docker-compose.yml.disabled"
      say 'APPS_LIST is empty: stopped the apps'
      return 0
    fi
    die 'APPS_LIST is empty; list your apps as name:port=image, such as game:8091=ghcr.io/you/game:latest'
  fi

  # The port may already be ours (Docker's proxy); anything else holds it.
  local name port cport image owner
  while read -r name port cport image; do
    owner="$(port_owner "$port")" || owner=""
    if [[ -n "$owner" && "$owner" != docker-proxy ]]; then
      die "Port $port of '$name' is used by $owner; pick a free port in APPS_LIST"
    fi
  done <<<"$apps"

  container_require_64bit APPS_LIST
  container_require_docker

  local uid
  uid="$(assign_uid apps)"
  install -m 0755 -d "$dir"
  apps_compose "$uid" <<<"$apps" | write_if_changed "$dir/docker-compose.yml" 0644 || true

  # Pulling every run brings a moving tag such as :latest up to date; "up"
  # then recreates only the apps whose image or settings changed, and
  # --remove-orphans takes down the ones no longer listed.
  container_pull "$dir"
  container_up "$dir" "$(head -n1 <<<"$apps" | cut -d' ' -f1)"
  while read -r name port cport image; do
    container_wait_stable "$name" ||
      container_fail "$dir" "$name" "The $name container does not stay up"
    say "$name is running: $(service_url "$port")"
  done <<<"$apps"
}
