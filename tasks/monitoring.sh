#!/usr/bin/env bash
# Task: monitoring - Netdata for real-time system dashboards.
# Settings: MONITORING_* in config/rpi-setup.env (names in config/tasks/monitoring.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("monitoring|Netdata monitoring dashboard (web UI :19999)")

run_monitoring() {
  : "${MONITORING_PORT:=19999}" "${MONITORING_BIND:=0.0.0.0}" "${MONITORING_TELEMETRY:=no}"
  : "${MONITORING_DOCKER:=no}"
  require_port MONITORING_PORT
  [[ "$MONITORING_BIND" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}|localhost|\*)$ ]] ||
    die "MONITORING_BIND must be an IPv4 address such as 0.0.0.0 (all) or 127.0.0.1 (got '$MONITORING_BIND')"
  setting_on MONITORING_TELEMETRY || true
  if setting_on MONITORING_DOCKER; then run_monitoring_container; return; fi
  container_leave monitoring

  # Written before the install, so a fresh Netdata never reports and needs
  # no restart.
  local changed=0
  if monitoring_optout /etc/netdata && apt_installed netdata; then changed=1; fi

  if ! apt_installed netdata; then
    apt_update
    if ! apt_has_candidate netdata; then
      # Debian 13 (Trixie, today's Raspberry Pi OS) no longer ships netdata;
      # use Netdata's own apt repository, as its official installer does.
      add_netdata_repo
    fi
    apt_install netdata
  fi

  # Debian's netdata package only listens on 127.0.0.1, so the dashboard would
  # be unreachable from other machines. Bind where MONITORING_BIND says
  # (default: all interfaces) and on MONITORING_PORT (idempotent).
  local conf=/etc/netdata/netdata.conf
  if netdata_set_bind "$conf" "$MONITORING_BIND"; then
    changed=1
    info "Netdata now listens on $MONITORING_BIND ($conf)"
  fi
  if netdata_set_port "$conf" "$MONITORING_PORT"; then
    changed=1
    info "Netdata now listens on port $MONITORING_PORT ($conf)"
  fi

  systemctl enable --now netdata
  if [[ $changed -eq 1 ]]; then
    systemctl restart netdata
  fi

  say "Netdata dashboard: $(service_url "$MONITORING_PORT" "$MONITORING_BIND")"
}

# Netdata's documented opt-out of anonymous usage statistics in its config
# folder $1, present unless MONITORING_TELEMETRY is on. Returns 0 if it changed.
monitoring_optout() {
  local f="$1/.opt-out-from-anonymous-statistics"
  if setting_on MONITORING_TELEMETRY; then
    [[ -e "$f" ]] || return 1
    rm -f "$f" || die "Could not remove $f"
  else
    [[ ! -e "$f" ]] || return 1
    { install -m 0755 -d "$1" && touch "$f"; } || die "Could not create $f"
  fi
}

# Point every "bind socket to IP" / "bind to" line of netdata.conf at $2, or
# add "bind to" under [web] when there is none and $2 is not the default
# (all interfaces). Returns 0 if the file was changed.
netdata_set_bind() {
  local conf="$1" ip="$2"
  local re='^([[:space:]]*(bind socket to IP|bind to)[[:space:]]*=[[:space:]]*)(.*[^[:space:]])[[:space:]]*$'
  if [[ -f "$conf" ]] && grep -Eq "$re" "$conf"; then
    # Nothing to do when every bind line already says $ip.
    grep -E "$re" "$conf" | sed -E "s/$re/\\3/" | grep -qvxF "$ip" || return 1
    sed -Ei "s/$re/\\1$ip/" "$conf"
    return 0
  fi
  [[ "$ip" != 0.0.0.0 && "$ip" != '*' ]] || return 1
  ini_set "$conf" web 'bind to' "$ip"
}

# Set [web] "default port" in netdata.conf, unless it is already $2 (19999,
# Netdata's default, needs no line). Returns 0 if the file was changed.
netdata_set_port() {
  local conf="$1" port="$2" cur
  cur="$(sed -nE 's/^[[:space:]]*default port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$conf" 2>/dev/null | head -n1)"
  [[ "${cur:-19999}" != "$port" ]] || return 1
  ini_set "$conf" web 'default port' "$port"
}

# True if apt can install package $1 from a configured source.
apt_has_candidate() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Add Netdata's signed stable apt repository for this OS release.
add_netdata_repo() {
  local codename
  codename=$( . /etc/os-release && echo "${VERSION_CODENAME:-}" ) || true
  [[ -n "$codename" ]] || die 'Could not determine the OS release (VERSION_CODENAME) for the Netdata repository.'
  info "netdata is not in the ${codename} archive; adding Netdata's apt repository"
  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://repo.netdata.cloud/netdatabot.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/netdata.gpg
  chmod a+r /etc/apt/keyrings/netdata.gpg
  echo "deb [signed-by=/etc/apt/keyrings/netdata.gpg] https://repository.netdata.cloud/repos/stable/debian/ ${codename}/" \
    >/etc/apt/sources.list.d/netdata.list
  apt_update_now
  apt_has_candidate netdata || die "Netdata publishes no package for '${codename}' on this architecture; skip the monitoring task."
}

# MONITORING_DOCKER=yes: Netdata's official image, set up as Netdata
# documents it (host network and PID namespace, the host's /proc, /sys and
# / read-only), with its config, database and cache in /opt/monitoring. A
# native netdata is stopped; its metric history is not carried over.
run_monitoring_container() {
  : "${MONITORING_IMAGE:=netdata/netdata:stable}"
  require_image_ref MONITORING_IMAGE
  container_require_64bit MONITORING_DOCKER
  container_require_docker
  local dir name=netdata owner="" changed=0
  dir="$(container_dir monitoring)"
  owner="$(port_owner "$MONITORING_PORT")" || owner=""
  [[ -z "$owner" || "$owner" == netdata ]] ||
    die "MONITORING_PORT=$MONITORING_PORT is already used by '$owner'; pick another port"

  install -m 0755 -d "$dir" "$dir/config" "$dir/lib" "$dir/cache"
  if monitoring_container_compose "$dir" "$name" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  # The same netdata.conf settings as the native install, in the mounted /etc/netdata.
  local conf="$dir/config/netdata.conf"
  if netdata_set_bind "$conf" "$MONITORING_BIND"; then changed=1; fi
  if netdata_set_port "$conf" "$MONITORING_PORT"; then changed=1; fi
  if monitoring_optout "$dir/config"; then changed=1; fi
  container_pull "$dir"
  container_stop_native "$dir" netdata

  container_up "$dir" "$name" "$changed"
  say "Netdata container running: $(service_url "$MONITORING_PORT" "$MONITORING_BIND")"
}

# Compose file of the Netdata container in folder $1, container name $2.
# Netdata's collectors start as root and need ptrace and their setuid/caps
# plugins, so unlike the other containers it keeps Docker's default
# capabilities and may gain privileges. The Docker socket is not mounted
# (it would give the container root on the Pi); containers show up by ID.
monitoring_container_compose() {
  local dir="$1" name="$2" track="" root=ro
  setting_on MONITORING_TELEMETRY || track='      DO_NOT_TRACK: "1"'
  # rslave (see mounts made later, e.g. a USB disk) needs / to be a shared
  # mount, as systemd makes it; plain read-only elsewhere.
  [[ "$(findmnt -no PROPAGATION / 2>/dev/null)" != shared* ]] || root=ro,rslave
  cat <<EOF
services:
  netdata:
    image: "$MONITORING_IMAGE"
    container_name: $name
    hostname: $(hostname)
    restart: unless-stopped
    network_mode: host
    pid: host
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    environment:
      NETDATA_LISTENER_PORT: "$MONITORING_PORT"
${track}
    volumes:
      - $dir/config:/etc/netdata
      - $dir/lib:/var/lib/netdata
      - $dir/cache:/var/cache/netdata
      - /:/host/root:${root}
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/hostname:/host/etc/hostname:ro
      - /etc/localtime:/etc/localtime:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/log:/host/var/log:ro
EOF
}
