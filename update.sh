#!/usr/bin/env bash
# update.sh - keep a provisioned Pi current: OS packages, rpi-setup's
# containers, Pi-hole and the EEPROM firmware. Each step runs only if that
# thing is installed; a failed step is reported and the others still run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# Overridable so the unit tests can point them at a temp dir.
UPDATE_OPT_DIR="${RPI_SETUP_OPT_DIR:-/opt}"
UPDATE_REBOOT_FILE="${RPI_SETUP_REBOOT_FILE:-/run/reboot-required}"

DRY_RUN=0
DO_APT=1
DO_CONTAINERS=1
declare -a UPDATE_RESULTS=()
UPDATE_FAILED=0

usage() {
  cat <<EOF
Usage: sudo bash update.sh [options]
Update everything rpi-setup installed on this Pi:
  - OS packages (apt-get update and upgrade)
  - the Docker containers of rpi-setup tasks (pull new images, recreate changed ones)
  - Pi-hole (pihole -up), if installed
  - the EEPROM firmware (rpi-eeprom-update -a), on a Raspberry Pi
Options:
  --dry-run        print the commands instead of running them
  --no-apt         skip the OS package upgrade
  --no-containers  skip the container update
  -h, --help       show this help
EOF
}

# Run a command, or only print it with --dry-run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  info "Running: $*"
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Record a step's outcome for the summary.
result() {
  UPDATE_RESULTS+=("$(printf '%-11s %s' "$1" "$2")")
  [[ "$2" != failed* ]] || UPDATE_FAILED=1
}

# Compose files written by rpi-setup tasks: /opt/<task>/docker-compose.yml
# where <task> is one of tasks/*.sh (e.g. /opt/netalertx, /opt/teamspeak).
compose_projects() {
  local f task
  for f in "$SCRIPT_DIR"/tasks/*.sh; do
    task="$(basename "$f" .sh)"
    [[ -f "$UPDATE_OPT_DIR/$task/docker-compose.yml" ]] &&
      printf '%s\n' "$UPDATE_OPT_DIR/$task/docker-compose.yml"
  done
  return 0
}

step_apt() {
  run apt-get update -y || return 1
  # --with-new-pkgs installs new dependencies (e.g. a new kernel package)
  # instead of holding the upgrade back, but never removes packages.
  run apt-get upgrade -y --with-new-pkgs "${APT_DPKG_OPTS[@]}"
}

# Pull every project's images, then "up -d": Compose recreates only the
# containers whose image or configuration changed.
step_containers() {
  local file rc=0
  for file in "$@"; do
    hr
    info "Updating $file"
    if run docker compose -f "$file" pull && run docker compose -f "$file" up -d; then
      say "Updated $file"
    else
      warn "Could not update $file (inspect with: docker compose -f $file logs)"
      rc=1
    fi
  done
  run docker image prune -f || rc=1
  return "$rc"
}

step_pihole() { run pihole -up; }

step_eeprom() { run rpi-eeprom-update -a; }

# Run step $2 (a function, with args $3...) and record it under name $1.
do_step() {
  local name="$1"; shift
  hr
  info "Step: $name"
  if "$@"; then
    say "$name: done"
    result "$name" ok
  else
    warn "$name: failed, continuing with the next step"
    result "$name" failed
  fi
}

skip_step() {
  info "Skipping $1: $2"
  result "$1" "skipped ($2)"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --no-apt) DO_APT=0 ;;
      --no-containers) DO_CONTAINERS=0 ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
  [[ $DRY_RUN -eq 1 ]] || need_root
  export DEBIAN_FRONTEND=noninteractive

  if [[ $DO_APT -eq 0 ]]; then
    skip_step apt '--no-apt'
  elif have apt-get; then
    do_step apt step_apt
  else
    skip_step apt 'apt-get not found'
  fi

  local -a projects=()
  mapfile -t projects < <(compose_projects)
  if [[ $DO_CONTAINERS -eq 0 ]]; then
    skip_step containers '--no-containers'
  elif ! have docker; then
    skip_step containers 'Docker not installed'
  elif [[ ${#projects[@]} -eq 0 ]]; then
    skip_step containers "no rpi-setup compose project under $UPDATE_OPT_DIR"
  else
    do_step containers step_containers "${projects[@]}"
  fi

  if have pihole; then
    do_step pihole step_pihole
  else
    skip_step pihole 'Pi-hole not installed'
  fi

  if ! is_pi; then
    skip_step eeprom 'not a Raspberry Pi'
  elif have rpi-eeprom-update; then
    do_step eeprom step_eeprom
  else
    skip_step eeprom 'rpi-eeprom-update not found'
  fi

  hr
  echo 'Summary:'
  local line
  for line in "${UPDATE_RESULTS[@]}"; do printf '  %s\n' "$line"; done
  if [[ -e "$UPDATE_REBOOT_FILE" ]]; then
    info "Reboot recommended ($UPDATE_REBOOT_FILE exists): sudo reboot"
  fi
  if [[ $UPDATE_FAILED -ne 0 ]]; then
    warn 'Some steps failed; see the messages above.'
    return 1
  fi
  say 'Update finished.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
