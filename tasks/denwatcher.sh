#!/usr/bin/env bash
# Task: denwatcher - Den-Watcher hardware usage website (Docker).
# Settings: DENWATCHER_* in config/rpi-setup.env (names in config/tasks/denwatcher.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("denwatcher|Den-Watcher: CPU, memory and temperature of the Pi in the browser (:9393)")

# Den-Watcher's add-ons that run in a container of their own, besides the
# containers add-on (DENWATCHER_CONTAINERS). gpu, inodes and smart have no
# container (they need the host's tools, filesystems or raw disks).
denwatcher_all_addons='power pressure kernel wifi bluetooth memory ports processes'

# Where systemd-rfkill keeps the radios' blocks for the next boot.
denwatcher_rfkill_dir=/var/lib/systemd/rfkill

# denwatcher_compose IMAGE PORT [ROUTERS] [DOCKER_DIR] [ADDONS] [RETENTION_DAYS] [STATUS_PORT]
# - the compose file:
# the host's /proc and /sys read-only (gopsutil reads them through
# HOST_PROC/HOST_SYS), the website on PORT (the container listens on 9393),
# the routers to show (HUB_ROUTERS) with their passwords from router-secrets/,
# the history in a named volume, no capabilities and a read-only root file
# system, and labels that give its card on the web task's start page a name
# and description, which every version of that page reads. With DOCKER_DIR
# (Docker's data folder) also Den-Watcher's containers add-on, see
# denwatcher_compose_containers, and with ADDONS (space separated, from
# denwatcher_all_addons) those add-ons, see denwatcher_compose_addon. The
# host's time zone is mounted so the page shows local times. With STATUS_PORT
# also Den-Watcher's status page for outside the local network, published on
# that port (the container serves it on 9443, over HTTPS and behind a password).
denwatcher_compose() {
  local addon with_addons=""
  [[ -z "${4:-}${5:-}" ]] || with_addons=1
  cat <<EOF2
services:
  den-watcher:
    image: "$1"
    container_name: den-watcher
    restart: unless-stopped
    labels:
      rpi-setup.link.name: "Den-Watcher"
      rpi-setup.link.description: "CPU, memory, temperature and disks of this Pi, with their history"
      rpi-setup.link.port: "$2"
    ports:
      - "0.0.0.0:$2:9393"
EOF2
  [[ -z "${7:-}" ]] || echo "      - \"0.0.0.0:$7:9443\""
  cat <<EOF2
    environment:
      PUBLIC_PORT: "$2"
      HOST_PROC: /host/proc
      HOST_SYS: /host/sys
      HUB_ROUTERS: "${3:-}"
      ROUTER_PASSWORDS_FILE: /run/secrets/router-passwords
EOF2
  [[ -z "${6:-}" ]] || echo "      RETENTION_DAYS: \"$6\""
  [[ -z "${7:-}" ]] || printf '      STATUS_ADDR: ":9443"\n      STATUS_PUBLIC_PORT: "%s"\n' "$7"
  [[ -z "$with_addons" ]] || echo "      ADDONS_DIR: /addons"
  cat <<EOF2
    volumes:
      - data:/data
      - ./router-secrets:/run/secrets:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/localtime:/etc/localtime:ro
EOF2
  [[ -z "$with_addons" ]] || echo "      - addons:/addons:ro"
  cat <<EOF2
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
  [[ -z "${4:-}" ]] || denwatcher_compose_containers "$1" "$4"
  for addon in ${5:-}; do denwatcher_compose_addon "$1" "$addon"; done
  cat <<EOF2
volumes:
  data:
EOF2
  # In memory only: the add-ons' newest values. A new tmpfs is open to
  # everyone (mode 1777), so the non-root users can write and read it.
  [[ -z "$with_addons" ]] || cat <<EOF2
  addons:
    driver_opts:
      type: tmpfs
      device: tmpfs
EOF2
}

# denwatcher_compose_containers IMAGE DOCKER_DIR - the containers add-on's
# service, as in Den-Watcher's own compose.yaml: it reads each running
# container's CPU and memory from the host's cgroups and their names from
# DOCKER_DIR/containers, both read-only, and writes them to the in-memory
# addons volume the website reads. It never gets the Docker socket, which
# would give it control of the Pi. It runs as root only so it may read those
# names (root-only files), but without any capability, network or writable
# file system. Compose does not create a missing DOCKER_DIR/containers.
denwatcher_compose_containers() {
  cat <<EOF2
  den-watcher-containers:
    image: "$1"
    container_name: den-watcher-containers
    restart: unless-stopped
    entrypoint: ["/den-watcher-containers"]
    user: "0:0"
    environment:
      HOST_SYS: /host/sys
      ADDONS_DIR: /addons
      DOCKER_DIR: /host/docker
    volumes:
      - addons:/addons
      - /sys/fs/cgroup:/host/sys/fs/cgroup:ro
      - type: bind
        source: "$2/containers"
        target: /host/docker/containers
        read_only: true
        bind:
          create_host_path: false
    network_mode: none
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
}

# denwatcher_compose_addon IMAGE ADDON - the service of one add-on from
# denwatcher_all_addons, as in Den-Watcher's own compose.yaml: the add-on's
# program from the same image, reading the host's /proc or /sys read-only and
# writing to the in-memory addons volume, without any capability, network or
# writable file system. It runs as the image's non-root user, except power,
# which needs root for the CPU's energy counters; bluetooth and wifi also read
# the host's system D-Bus (a file socket, not network), only to list the
# devices and the Wi-Fi networks nearby that NetworkManager found.
denwatcher_compose_addon() {
  local user="" env mounts
  case "$2" in
    power)
      user='    user: "0:0"'
      env='      HOST_SYS: /host/sys'
      mounts='      - /sys:/host/sys:ro' ;;
    bluetooth)
      env=$'      HOST_SYS: /host/sys\n      DBUS_SYSTEM_BUS_ADDRESS: unix:path=/host/run/dbus/system_bus_socket'
      mounts=$'      - /sys:/host/sys:ro\n      - /run/dbus:/host/run/dbus:ro' ;;
    wifi)
      env=$'      HOST_PROC: /host/proc\n      DBUS_SYSTEM_BUS_ADDRESS: unix:path=/host/run/dbus/system_bus_socket'
      mounts=$'      - /proc:/host/proc:ro\n      - /run/dbus:/host/run/dbus:ro' ;;
    *)
      env='      HOST_PROC: /host/proc'
      mounts='      - /proc:/host/proc:ro' ;;
  esac
  cat <<EOF2
  den-watcher-$2:
    image: "$1"
    container_name: den-watcher-$2
    restart: unless-stopped
    entrypoint: ["/den-watcher-$2"]
EOF2
  [[ -z "$user" ]] || printf '%s\n' "$user"
  cat <<EOF2
    environment:
$env
      ADDONS_DIR: /addons
    volumes:
      - addons:/addons
$mounts
    network_mode: none
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
}

# denwatcher_move_old DIR PASSWORDS - moves an install of the usagecontrol
# task, Den-Watcher's task before the rename, to this one, once: it creates
# this project's data volume (through Compose, so it stays Compose's), stops
# the old containers, copies the history from the volume usagecontrol_data
# into the new one, keeps the router passwords under the new name and only
# then removes the old containers and /opt/usagecontrol, so the old install
# keeps running until the new one has what it needs. The old volume stays as
# a backup. A copy cut short (power lost) is not repeated over: the next run
# finds the new volume not empty and goes on with it.
denwatcher_move_old() {
  local dir="$1" passwords="$2" old from="" to="" copy=0
  old="$(container_dir usagecontrol)"
  [[ -f "$old/docker-compose.yml" ]] || return 0
  info "Moving the usagecontrol task's install from before the rename in $old to $dir"
  if docker volume inspect usagecontrol_data >/dev/null 2>&1; then
    docker compose -f "$dir/docker-compose.yml" create den-watcher ||
      die "Could not create the den-watcher container and its volume in $dir; the old install keeps running"
    from="$(docker volume inspect -f '{{.Mountpoint}}' usagecontrol_data)" || from=""
    to="$(docker volume inspect -f '{{.Mountpoint}}' denwatcher_data)" || to=""
    [[ -n "$from" && -d "$from" && -n "$to" && -d "$to" ]] ||
      die "Could not find the folders of the volumes usagecontrol_data and denwatcher_data; is Docker's local volume driver in use? The old install keeps running"
    if [[ -n "$(ls -A "$to")" ]]; then
      info "denwatcher_data already holds a history; keeping it"
    else
      copy=1
    fi
  fi
  # Stopped, not removed, while the history is copied: nothing writes to it
  # meanwhile, and a failed copy starts the old install again.
  docker compose -f "$old/docker-compose.yml" stop ||
    die "Could not stop the old install in $old; stop it with: cd $old && sudo docker compose down"
  if [[ $copy -eq 1 ]]; then
    if cp -a "$from/." "$to/"; then
      say "Copied the history from usagecontrol_data to denwatcher_data"
    else
      find "$to" -mindepth 1 -delete 2>/dev/null || true
      docker compose -f "$old/docker-compose.yml" start >/dev/null 2>&1 || true
      die "Could not copy the history from usagecontrol_data to denwatcher_data; the old install is running again"
    fi
  fi
  docker compose -f "$old/docker-compose.yml" down ||
    die "Could not remove the old install in $old; remove it with: cd $old && sudo docker compose down"
  if [[ -n "$passwords" ]] && ! load_secret denwatcher DENWATCHER_ROUTER_PASSWORD >/dev/null; then
    save_secret denwatcher DENWATCHER_ROUTER_PASSWORD "$passwords"
  fi
  rm -f /var/lib/rpi-setup/secrets/usagecontrol.env
  docker volume rm usagecontrol_addons >/dev/null 2>&1 || true
  rm -rf "$old"
  if docker volume inspect usagecontrol_data >/dev/null 2>&1; then
    info "The old volume usagecontrol_data stays as a backup; once the history shows in Den-Watcher, remove it with: sudo docker volume rm usagecontrol_data"
  fi
}

# denwatcher_wifi_radio COUNTRY - switches the Wi-Fi radio on where it is
# off, so the wifi add-on hears the networks nearby on a Pi on cable too.
# Raspberry Pi OS keeps the radio blocked (rfkill) until a Wi-Fi country is
# set, so it sets COUNTRY first, with raspi-config where there is one. The
# radio only listens: NetworkManager joins no network that is not saved.
denwatcher_wifi_radio() {
  local list="" off=0 f
  command -v rfkill >/dev/null 2>&1 && list="$(rfkill list wlan 2>/dev/null)" || true
  if grep -q 'Hard blocked: yes' <<<"$list"; then
    warn "The Wi-Fi radio is switched off by a hardware switch, so the wifi add-on hears no networks nearby"
    return 0
  fi
  grep -q 'Soft blocked: yes' <<<"$list" && off=1
  if command -v nmcli >/dev/null 2>&1 && [[ "$(nmcli radio wifi 2>/dev/null)" == disabled ]]; then off=1; fi
  [[ $off -eq 1 ]] || return 0
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "$1" >/dev/null 2>&1 ||
      warn "raspi-config could not set the Wi-Fi country $1"
  elif command -v iw >/dev/null 2>&1; then
    iw reg set "$1" 2>/dev/null || true
  fi
  rfkill unblock wifi 2>/dev/null || true
  # systemd-rfkill restores the block at the next boot from these files.
  for f in "$denwatcher_rfkill_dir"/*:wlan; do
    [[ ! -e "$f" ]] || echo 0 >"$f"
  done
  if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi on 2>/dev/null || warn "NetworkManager did not switch the Wi-Fi radio on (nmcli radio wifi on)"
  fi
  say "Switched the Wi-Fi radio on (country $1), so the wifi add-on hears the networks nearby; it joins no network"
}

run_denwatcher() {
  : "${DENWATCHER_PORT:=9393}" "${DENWATCHER_IMAGE:=ghcr.io/programmer-den/den-watcher:main}" "${DENWATCHER_ROUTER_PASSWORD:=}" "${DENWATCHER_CONTAINERS:=yes}" \
    "${DENWATCHER_ADDONS:=all}" "${DENWATCHER_RETENTION_DAYS:=}" "${DENWATCHER_STATUS_PORT:=}" "${DENWATCHER_WIFI_COUNTRY:=DE}"
  require_port DENWATCHER_PORT
  if [[ -n "$DENWATCHER_STATUS_PORT" ]]; then
    require_port DENWATCHER_STATUS_PORT
    [[ "$DENWATCHER_STATUS_PORT" != "$DENWATCHER_PORT" ]] ||
      die "DENWATCHER_STATUS_PORT must differ from DENWATCHER_PORT (both are $DENWATCHER_PORT)"
  fi
  require_image_ref DENWATCHER_IMAGE
  # Images under Den-Watcher's old name run the containers add-on under its old
  # name too, and that name is published only up to 3.0.0.
  [[ ! "$DENWATCHER_IMAGE" =~ /usage-control([:@][^/]*)?$ ]] ||
    die "DENWATCHER_IMAGE names Den-Watcher's old image ($DENWATCHER_IMAGE); set it to ghcr.io/programmer-den/den-watcher:main or a release published there"
  # Den-Watcher moved to Programmer-Den; the image under the old owner keeps
  # its versions but gets no new ones.
  [[ ! "$DENWATCHER_IMAGE" =~ (^|/)chriszly/den-watcher([:@][^/]*)?$ ]] ||
    warn "DENWATCHER_IMAGE ($DENWATCHER_IMAGE) gets no new versions since Den-Watcher moved; set it to ghcr.io/programmer-den/den-watcher with :main or a release published there"
  local containers=0
  if setting_on DENWATCHER_CONTAINERS; then containers=1; fi
  local addons="" addon
  case "${DENWATCHER_ADDONS,,}" in
    all) addons="$denwatcher_all_addons" ;;
    none) ;;
    *)
      for addon in ${DENWATCHER_ADDONS//,/ }; do
        [[ " $denwatcher_all_addons " == *" $addon "* ]] ||
          die "DENWATCHER_ADDONS must be all, none or add-ons from: ${denwatcher_all_addons// /, } (got '$addon')"
        [[ " $addons " == *" $addon "* ]] || addons+="${addons:+ }$addon"
      done ;;
  esac
  [[ "${DENWATCHER_WIFI_COUNTRY,,}" == no ]] || DENWATCHER_WIFI_COUNTRY="${DENWATCHER_WIFI_COUNTRY^^}"
  [[ "$DENWATCHER_WIFI_COUNTRY" =~ ^([A-Z]{2}|[Nn][Oo])$ ]] ||
    die "DENWATCHER_WIFI_COUNTRY must be a 2-letter country code such as DE, AT, CH, GB or US, or no (got '$DENWATCHER_WIFI_COUNTRY')"
  if [[ -n "$DENWATCHER_RETENTION_DAYS" ]] &&
    { [[ ! "$DENWATCHER_RETENTION_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] || (( DENWATCHER_RETENTION_DAYS > 3650 )); }; then
    die "DENWATCHER_RETENTION_DAYS must be a number of days from 1 to 3650 (got '$DENWATCHER_RETENTION_DAYS')"
  fi
  # Den-Watcher checks each router itself; here only what could break the
  # compose file (quotes, $, backslashes, line breaks) is refused.
  local safe='^[][A-Za-z0-9 ._@:=,-]*$'
  [[ "${DENWATCHER_ROUTERS:-}" =~ $safe ]] ||
    die "DENWATCHER_ROUTERS must be name=protocol:address entries, such as Router=upnp:192.168.1.1, with only letters, digits, spaces and . _ @ : = , - [ ] (got '${DENWATCHER_ROUTERS}')"

  # Router passwords: from DENWATCHER_ROUTER_PASSWORD, kept for the next
  # runs, or the ones kept from an earlier run, so they never need to be in
  # the settings file.
  local passwords="$DENWATCHER_ROUTER_PASSWORD" entry named='^ *[^= ][^=]*=.+$'
  if [[ -n "$passwords" ]]; then
    local -a entries
    [[ "$passwords" != *$'\n'* ]] || die "DENWATCHER_ROUTER_PASSWORD must be on one line"
    IFS=, read -ra entries <<<"$passwords"
    for entry in "${entries[@]}"; do
      # The value is not shown, as it holds passwords.
      [[ "$entry" =~ $named ]] ||
        die "DENWATCHER_ROUTER_PASSWORD must be name=password entries, comma-separated, such as Router=secret"
    done
  else
    passwords="$(load_secret denwatcher DENWATCHER_ROUTER_PASSWORD)" ||
      passwords="$(load_secret usagecontrol USAGECONTROL_ROUTER_PASSWORD)" || passwords=""
  fi

  # The image is published for arm64 and amd64 only.
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == arm64 || "$arch" == amd64 ]] ||
    die "The Den-Watcher image needs a 64-bit OS (this one is $arch). Flash Raspberry Pi OS Lite (64-bit)."

  # The ports may already be ours (Docker's proxy); anything else holds them.
  local owner setting
  for setting in DENWATCHER_PORT DENWATCHER_STATUS_PORT; do
    [[ -n "${!setting}" ]] || continue
    owner="$(port_owner "${!setting}")" || owner=""
    if [[ -n "$owner" && "$owner" != docker-proxy ]]; then
      die "Port ${!setting} is used by $owner; set $setting to a free port"
    fi
  done

  container_require_docker

  # The containers add-on reads the names from Docker's data folder, wherever
  # Docker keeps it (data-root in /etc/docker/daemon.json).
  local docker_dir=""
  if [[ $containers -eq 1 ]]; then
    docker_dir="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)" ||
      die "Could not ask Docker for its data folder (docker info); is the Docker service running?"
    [[ "$docker_dir" =~ ^/[A-Za-z0-9._/-]*$ ]] ||
      die "Docker's data folder '$docker_dir' has characters the compose file cannot hold; set DENWATCHER_CONTAINERS=no"
    if [[ ! -d "$docker_dir/containers" ]]; then
      warn "No $docker_dir/containers folder, so the containers add-on is left out; set DENWATCHER_CONTAINERS=no to silence this"
      docker_dir=""
    elif ! grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
      info "The kernel counts no memory per container, so Den-Watcher shows only their CPU. For their memory too, add cgroup_enable=memory to /boot/firmware/cmdline.txt and reboot."
    fi
  fi

  # The Bluetooth add-on asks BlueZ and the Wi-Fi add-on NetworkManager
  # through the system D-Bus; without it Docker would create an empty
  # /run/dbus, so they are left out.
  local addon
  for addon in bluetooth wifi; do
    if [[ " $addons " == *" $addon "* && ! -S /run/dbus/system_bus_socket ]]; then
      warn "No system D-Bus (/run/dbus/system_bus_socket), so the $addon add-on is left out"
      addons="$(tr ' ' '\n' <<<"$addons" | grep -vx "$addon" | xargs)"
    fi
  done

  if [[ " $addons " == *" wifi "* && "${DENWATCHER_WIFI_COUNTRY,,}" != no ]]; then
    denwatcher_wifi_radio "$DENWATCHER_WIFI_COUNTRY"
  fi

  local dir name=den-watcher changed=0
  dir="$(container_dir denwatcher)"
  install -m 0755 -d "$dir" "$dir/router-secrets"
  if denwatcher_compose "$DENWATCHER_IMAGE" "$DENWATCHER_PORT" "${DENWATCHER_ROUTERS:-}" "$docker_dir" "$addons" "$DENWATCHER_RETENTION_DAYS" "$DENWATCHER_STATUS_PORT" | write_if_changed "$dir/docker-compose.yml" 0644; then
    changed=1
  fi

  # The passwords file, one name=password per line, readable only by root
  # and the container's user. Den-Watcher reads it at start, so a changed
  # file restarts the container.
  # 65532 is the image's non-root user (distroless nonroot).
  local secrets="$dir/router-secrets/router-passwords" restart=0
  if [[ -n "$DENWATCHER_ROUTER_PASSWORD" ]]; then
    save_secret denwatcher DENWATCHER_ROUTER_PASSWORD "$passwords"
  fi
  if [[ -n "$passwords" ]]; then
    if tr ',' '\n' <<<"$passwords" | write_if_changed "$secrets" 0400; then
      restart=1
    fi
    chown 65532:65532 "$secrets"
  elif [[ -e "$secrets" ]]; then
    rm -f "$secrets"
    restart=1
  fi
  [[ $restart -eq 0 ]] || changed=1

  container_pull "$dir"
  denwatcher_move_old "$dir" "$passwords"
  container_up "$dir" "$name" "$restart"
  # The website runs without the add-on, so one that does not stay up only
  # warns, with its last log lines.
  if [[ -n "$docker_dir" ]] && ! container_wait_stable den-watcher-containers; then
    docker logs --tail 30 den-watcher-containers 2>&1 | sed 's/^/    /' >&2 || true
    warn "The containers add-on does not stay up, so Den-Watcher shows no containers; its last log lines are above"
  fi
  for addon in $addons; do
    container_wait_stable "den-watcher-$addon" && continue
    docker logs --tail 30 "den-watcher-$addon" 2>&1 | sed 's/^/    /' >&2 || true
    warn "The $addon add-on does not stay up, so Den-Watcher shows none of its values; its last log lines are above"
  done

  if [[ $changed -eq 1 ]]; then
    say "Den-Watcher is running with the new settings: $(service_url "$DENWATCHER_PORT")"
  else
    say "Den-Watcher is running: $(service_url "$DENWATCHER_PORT")"
  fi
  if [[ -n "$DENWATCHER_STATUS_PORT" ]]; then
    info "Status page for outside the local network: https://<public address>:$DENWATCHER_STATUS_PORT once the router forwards TCP $DENWATCHER_STATUS_PORT to this Pi; set its password in Den-Watcher under Devices > Remote status page"
  fi
}
