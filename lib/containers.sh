#!/usr/bin/env bash
# Helpers for tasks that run their service in a Docker container: netalertx
# and teamspeak always, the others with <TASK>_DOCKER=yes. Every container is
# its own compose project in /opt/<task>/ with its data in bind-mounted
# folders next to the compose file.
#
# Switching a task to its container keeps the native service until the
# container is proven: the image is pulled first, the native units are then
# stopped and recorded in /opt/<task>/.native-units, and if the container does
# not stay up they are started again. Switching back (<TASK>_DOCKER=no) takes
# the container down, starts the recorded units and renames the compose file
# to docker-compose.yml.disabled, so update.sh does not start it again.
#
# Loaded by the task files that use it (after lib/common.sh); safe to source
# more than once.
set -euo pipefail

# Make sure Docker and Compose are there; install them with the docker task
# (and its DOCKER_* settings) if not, so a container task just works.
container_require_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  [[ "$(type -t run_docker)" == function ]] || require_docker
  info 'Docker is not installed yet; running the docker task first'
  # Plain calls, not "A && B || C": errexit must stay on inside run_docker.
  load_task_config docker
  run_docker
  require_docker
}

# Dies unless this OS can run the arm64/amd64 images the tasks use.
container_require_64bit() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in
    arm64|amd64|aarch64|x86_64) return 0 ;;
  esac
  die "Containers need a 64-bit OS (this one is $arch). Flash Raspberry Pi OS Lite (64-bit), or set $1=no."
}

# Write NAME=value lines (the remaining arguments) to $1/secrets.env, root
# only. Compose passes it with env_file, so passwords never sit in the compose
# file. Returns 0 if the file changed.
container_write_secrets() {
  local dir="$1" kv
  shift
  for kv in "$@"; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "container_write_secrets: '$kv' is not NAME=value"
    [[ "$kv" != *$'\n'* ]] || die "container_write_secrets: ${kv%%=*} cannot contain a line break"
  done
  install -m 0700 -d "$dir"
  printf '%s\n' "$@" | write_if_changed "$dir/secrets.env" 0600
}

# Stop and disable native units $2... so the container can take their ports,
# and remember them in $1/.native-units for container_restore_native. Units
# that are not installed are skipped.
container_stop_native() {
  local dir="$1" unit
  shift
  install -m 0755 -d "$dir"
  for unit in "$@"; do
    unit_exists "$unit" || continue
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
      info "Stopping the native $unit service (the container takes over; packages stay installed)"
      systemctl disable --now "$unit" >/dev/null 2>&1 || warn "Could not stop $unit"
      grep -qxF "$unit" "$dir/.native-units" 2>/dev/null || printf '%s\n' "$unit" >>"$dir/.native-units"
    fi
  done
}

# Start the native units container_stop_native recorded in $1/.native-units.
container_restore_native() {
  local dir="$1" unit
  [[ -f "$dir/.native-units" ]] || return 0
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    unit_exists "$unit" || continue
    info "Starting the native $unit service again"
    systemctl enable --now "$unit" >/dev/null 2>&1 || warn "Could not start $unit; start it with: sudo systemctl enable --now $unit"
  done <"$dir/.native-units"
  rm -f "$dir/.native-units"
}

# Copy the contents of native folder $2 into $3 once (marker $1/.migrated-<name
# of $3>), keeping owners and modes. Returns 0 if it copied.
container_copy_once() {
  local dir="$1" src="$2" dest="$3" marker
  marker="$dir/.migrated-$(basename "$dest")"
  [[ ! -e "$marker" ]] || return 1
  [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]] || return 1
  install -m 0755 -d "$dest"
  cp -a "$src/." "$dest/"
  touch "$marker"
  info "Copied $src to $dest"
  return 0
}

# True if the kernel uses 16K memory pages (the Raspberry Pi 5 default).
container_16k_pages() { [[ "$(getconf PAGESIZE 2>/dev/null)" == 16384 ]]; }

# State of container $1: "running 0 healthy", "restarting 3 none", ... or
# empty if there is no such container.
container_state() {
  docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true
}

# Wait until container $1 has stayed up for $2 seconds (default 10) without
# restarting, then up to $3 seconds (default 120) for its health check if it
# has one. Returns 1 if it exits or restarts; a health check that is still
# starting at the end only warns.
container_wait_stable() {
  local name="$1" settle="${2:-10}" health_wait="${3:-120}" st status restarts health first="" i
  for (( i = 0; i <= settle; i++ )); do
    st="$(container_state "$name")"
    read -r status restarts health <<<"${st:-missing 0 none}"
    [[ -n "$first" ]] || first="$restarts"
    if [[ "$status" != running || "$restarts" != "$first" ]]; then
      return 1
    fi
    (( i == settle )) || sleep 1
  done
  [[ "$health" != none ]] || return 0
  for (( i = 0; i < health_wait; i++ )); do
    st="$(container_state "$name")"
    read -r status restarts health <<<"${st:-missing 0 none}"
    [[ "$status" == running && "$restarts" == "$first" ]] || return 1
    [[ "$health" != healthy ]] || return 0
    sleep 1
  done
  warn "$name is running but its health check still says '$health'; see: docker logs $name"
  return 0
}

# Pull the images of the compose project in $1, before anything on the host
# changes, so a wrong image name or a network problem stops the run early.
container_pull() {
  local file="$1/docker-compose.yml"
  info "Pulling the image(s) for $file"
  docker compose -f "$file" pull --quiet ||
    die "Could not pull the image(s) in $file; check the image setting and the network"
}

# Start (or update) the compose project in $1 and wait until container $2 is
# stable. $3=1 says the task changed its files: the container is then
# recreated, since Compose does not notice a changed bind-mounted config or
# secrets.env. If it is not stable, show its last log lines, take it down,
# start the native units again and stop the run.
container_up() {
  local dir="$1" name="$2" file="$1/docker-compose.yml" recreate=()
  if [[ "${3:-0}" -eq 1 ]]; then recreate=(--force-recreate); fi
  docker compose -f "$file" up -d --remove-orphans "${recreate[@]}" ||
    container_fail "$dir" "$name" "docker compose could not start $file"
  container_wait_stable "$name" ||
    container_fail "$dir" "$name" "The $name container does not stay up"
}

# Report a container that failed to start, roll back to the native service
# and die with message $3.
container_fail() {
  local dir="$1" name="$2" msg="$3"
  docker logs --tail 30 "$name" 2>&1 | sed 's/^/    /' >&2 || true
  if container_16k_pages; then
    warn 'This Pi runs the 16K-page kernel, which some images cannot run on.'
    warn 'Set BASE_PI5_4K_KERNEL=yes, run "sudo bash setup.sh base" and reboot, then try again.'
  fi
  docker compose -f "$dir/docker-compose.yml" down >/dev/null 2>&1 || true
  container_restore_native "$dir"
  die "$msg. Its last log lines are above; the native service (if any) is back."
}

# Switching task $1 back to native: take its container down if there is one,
# and start the native units it replaced. The data in /opt/<task> stays, but
# the compose file is renamed to docker-compose.yml.disabled so that update.sh
# and task_in_container no longer see a live project (update.sh would start the
# container again next to the native service). <TASK>_DOCKER=yes writes a fresh
# one. If "down" fails the file is kept, so the next run tries again.
# Not called for netalertx and teamspeak, which always run in a container.
container_leave() {
  local task="$1" dir file down=0
  dir="$(container_dir "$task")"
  file="$dir/docker-compose.yml"
  [[ -f "$file" ]] || return 0
  if command -v docker >/dev/null 2>&1; then
    if [[ -n "$(docker compose -f "$file" ps -aq 2>/dev/null)" ]]; then
      info "Stopping the $task container (${task^^}_DOCKER is off); its data stays in $dir"
      docker compose -f "$file" down >/dev/null 2>&1 || { warn "Could not stop the $task container"; down=1; }
    fi
    container_restore_native "$dir"
  fi
  [[ $down -eq 0 ]] || return 0
  mv -f "$file" "$file.disabled"
}
