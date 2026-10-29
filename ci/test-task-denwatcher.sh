#!/usr/bin/env bash
# test-task-denwatcher.sh - unit tests for tasks/denwatcher.sh: the
# compose file it writes, and the checks that stop it before anything changes.
#
# Run: bash ci/test-task-denwatcher.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/denwatcher.sh"

# --- the compose file -----------------------------------------------------------
out="$(denwatcher_compose ghcr.io/programmer-den/den-watcher:1.2.3 8090)"
assert_contains "compose: image" 'image: "ghcr.io/programmer-den/den-watcher:1.2.3"' "$out"
assert_contains "compose: port on the host" '"0.0.0.0:8090:9393"' "$out"
assert_contains "compose: port the page is reachable on" 'PUBLIC_PORT: "8090"' "$out"
assert_contains "compose: history kept in a volume" "data:/data" "$out"
assert_contains "compose: host /proc read-only" "/proc:/host/proc:ro" "$out"
assert_contains "compose: host /sys read-only" "/sys:/host/sys:ro" "$out"
assert_contains "compose: no capabilities" "- ALL" "$out"
assert_contains "compose: read-only file system" "read_only: true" "$out"
assert_contains "compose: no routers by default" 'HUB_ROUTERS: ""' "$out"
assert_contains "compose: card name on the start page" 'rpi-setup.link.name: "Den-Watcher"' "$out"
assert_contains "compose: card description on the start page" 'rpi-setup.link.description: "CPU, memory, temperature and disks of this Pi, with their history"' "$out"
assert_contains "compose: card links to the port on the host" 'rpi-setup.link.port: "8090"' "$out"
assert_contains "compose: router passwords mounted read-only" "./router-secrets:/run/secrets:ro" "$out"
out="$(denwatcher_compose ghcr.io/programmer-den/den-watcher:1.2.3 8090 'Router=upnp:192.168.1.1,Box=fritzbox:monitor@192.168.178.1')"
assert_contains "compose: routers" 'HUB_ROUTERS: "Router=upnp:192.168.1.1,Box=fritzbox:monitor@192.168.178.1"' "$out"
assert_lacks "compose: no containers add-on without Docker's folder" "den-watcher-containers" "$out"
assert_lacks "compose: no add-on folder without the add-on" "addons" "$out"
with="$(denwatcher_compose ghcr.io/programmer-den/den-watcher:1.2.3 8090 '' /srv/docker)"
assert_contains "containers: add-on service" "entrypoint: [\"/den-watcher-containers\"]" "$with"
assert_contains "containers: same image" $'den-watcher-containers:\n    image: "ghcr.io/programmer-den/den-watcher:1.2.3"' "$with"
assert_contains "compose: the website as den-watcher" $'den-watcher:\n    image: "ghcr.io/programmer-den/den-watcher:1.2.3"\n    container_name: den-watcher\n' "$with"
assert_contains "containers: names from Docker's folder" 'source: "/srv/docker/containers"' "$with"
assert_contains "containers: cgroups read-only" "/sys/fs/cgroup:/host/sys/fs/cgroup:ro" "$with"
assert_contains "containers: no network" "network_mode: none" "$with"
assert_lacks "containers: never the Docker socket" "docker.sock" "$with"
assert_contains "containers: website reads the add-on folder" "ADDONS_DIR: /addons" "$with"
assert_contains "containers: website mounts it read-only" "addons:/addons:ro" "$with"
assert_contains "containers: add-on folder in memory" "type: tmpfs" "$with"
all="$(denwatcher_compose ghcr.io/programmer-den/den-watcher:1.2.3 8090 '' '' "$denwatcher_all_addons" 365)"
assert_contains "addons: power runs its program" $'den-watcher-power:\n    image: "ghcr.io/programmer-den/den-watcher:1.2.3"\n    container_name: den-watcher-power\n    restart: unless-stopped\n    entrypoint: ["/den-watcher-power"]\n    user: "0:0"' "$all"
assert_contains "addons: processes as the image's user" $'entrypoint: ["/den-watcher-processes"]\n    environment:' "$all"
assert_contains "addons: bluetooth reads the system D-Bus read-only" "/run/dbus:/host/run/dbus:ro" "$all"
assert_contains "addons: wifi reads the system D-Bus too" $'entrypoint: ["/den-watcher-wifi"]\n    environment:\n      HOST_PROC: /host/proc\n      DBUS_SYSTEM_BUS_ADDRESS: unix:path=/host/run/dbus/system_bus_socket' "$all"
assert_eq "addons: one service per add-on" 8 "$(grep -c 'entrypoint: \["/den-watcher-' <<<"$all")"
assert_eq "addons: none with network" 8 "$(grep -c 'network_mode: none' <<<"$all")"
assert_contains "addons: website reads them without the containers add-on" "addons:/addons:ro" "$all"
assert_contains "compose: history kept for the days set" 'RETENTION_DAYS: "365"' "$all"
assert_lacks "compose: Den-Watcher's own history length by default" "RETENTION_DAYS" "$out"
assert_contains "compose: the Pi's time zone" "/etc/localtime:/etc/localtime:ro" "$out"
assert_lacks "compose: no status page by default" "9443" "$out"
status="$(denwatcher_compose ghcr.io/programmer-den/den-watcher:1.2.3 8090 '' '' '' '' 9444)"
assert_contains "status page: published on its port" $'      - "0.0.0.0:8090:9393"\n      - "0.0.0.0:9444:9443"\n    environment:' "$status"
assert_contains "status page: served inside the container" 'STATUS_ADDR: ":9443"' "$status"
assert_contains "status page: port the Devices dialog names" 'STATUS_PUBLIC_PORT: "9444"' "$status"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  printf '%s\n' "$out" >"$TMP/docker-compose.yml"
  assert_ok "compose: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
  printf '%s\n' "$all" >"$TMP/docker-compose.yml"
  assert_ok "addons: docker compose accepts them" docker compose -f "$TMP/docker-compose.yml" config -q
  printf '%s\n' "$with" >"$TMP/docker-compose.yml"
  assert_ok "containers: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
  printf '%s\n' "$status" >"$TMP/docker-compose.yml"
  assert_ok "status page: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
else
  skip "compose: docker compose not installed"
fi

# --- settings are checked before anything changes ------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
port_owner() { return 1; }
dpkg() { echo arm64; }
( DENWATCHER_PORT=70000; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad port stops the task" "DENWATCHER_PORT" "$(cat "$TMP/err")"
( DENWATCHER_IMAGE='Bad Image'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad image stops the task" "DENWATCHER_IMAGE must be a Docker image" "$(cat "$TMP/err")"
( DENWATCHER_IMAGE=ghcr.io/chriszly/usage-control:2.0.7a; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "old image name stops the task" "set it to ghcr.io/programmer-den/den-watcher:main" "$(cat "$TMP/err")"
( DENWATCHER_IMAGE=registry.local:5000/chriszly/usage-control@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "old image name by digest stops the task" "Den-Watcher's old image" "$(cat "$TMP/err")"
# The quote stops the task after the image checks, before anything is set up.
( DENWATCHER_IMAGE=ghcr.io/chriszly/den-watcher:latest; DENWATCHER_ROUTERS='Router=upnp:192.168.1.1"'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "image under the old owner warns" "gets no new versions since Den-Watcher moved" "$(cat "$TMP/err")"
( DENWATCHER_ROUTERS='Router=upnp:192.168.1.1"'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_lacks "new image name does not warn" "gets no new versions" "$(cat "$TMP/err")"
( DENWATCHER_ROUTERS='Router=upnp:192.168.1.1"'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "router with a quote stops the task" "DENWATCHER_ROUTERS must be" "$(cat "$TMP/err")"
# shellcheck disable=SC2016 # a literal $, as compose would expand it
( DENWATCHER_ROUTERS='Router=upnp:$HOME'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "router with a \$ stops the task" "DENWATCHER_ROUTERS must be" "$(cat "$TMP/err")"
( DENWATCHER_ROUTER_PASSWORD='hunter2'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "password without a name stops the task" "DENWATCHER_ROUTER_PASSWORD must be" "$(cat "$TMP/err")"
assert_lacks "password is not shown" "hunter2" "$(cat "$TMP/err")"
( DENWATCHER_ROUTER_PASSWORD='Box=a,=b'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "second password without a name stops the task" "DENWATCHER_ROUTER_PASSWORD must be" "$(cat "$TMP/err")"
( DENWATCHER_ADDONS=power,gpu; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "unknown add-on stops the task" "DENWATCHER_ADDONS must be all, none or add-ons from" "$(cat "$TMP/err")"
( DENWATCHER_RETENTION_DAYS=3651; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "too long a history stops the task" "DENWATCHER_RETENTION_DAYS must be a number of days from 1 to 3650" "$(cat "$TMP/err")"
( DENWATCHER_RETENTION_DAYS=0; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "no history stops the task" "DENWATCHER_RETENTION_DAYS must be" "$(cat "$TMP/err")"
( DENWATCHER_STATUS_PORT=70000; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad status port stops the task" "DENWATCHER_STATUS_PORT" "$(cat "$TMP/err")"
( DENWATCHER_STATUS_PORT=9393; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "status page on the website's port stops the task" "DENWATCHER_STATUS_PORT must differ from DENWATCHER_PORT" "$(cat "$TMP/err")"
( DENWATCHER_CONTAINERS=maybe; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad containers setting stops the task" "DENWATCHER_CONTAINERS must be yes or no" "$(cat "$TMP/err")"
( DENWATCHER_WIFI_COUNTRY=DEU; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad Wi-Fi country stops the task" "DENWATCHER_WIFI_COUNTRY must be a 2-letter country code" "$(cat "$TMP/err")"
# The country codes raspi-config offers, as tzdata lists them.
denwatcher_iso3166="$TMP/iso3166.tab"
printf '#country-code\tname\nAT\tAustria\nDE\tGermany\nNO\tNorway\n' >"$denwatcher_iso3166"
( DENWATCHER_WIFI_COUNTRY=XX; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "unknown Wi-Fi country stops the task" "DENWATCHER_WIFI_COUNTRY must be a country code from $denwatcher_iso3166" "$(cat "$TMP/err")"
( DENWATCHER_WIFI_COUNTRY=no; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "the old opt-out no stops the task" "set DENWATCHER_WIFI_RADIO=no for that, or NO (upper case) for Norway" "$(cat "$TMP/err")"
( DENWATCHER_WIFI_RADIO=maybe; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad Wi-Fi radio setting stops the task" "DENWATCHER_WIFI_RADIO must be yes or no" "$(cat "$TMP/err")"
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
( DENWATCHER_WIFI_COUNTRY=NO DENWATCHER_ROUTERS='Router=upnp:192.168.1.1"'; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_lacks "Norway is a country" "DENWATCHER_WIFI" "$(cat "$TMP/err")"
( DENWATCHER_PORT=8080 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { echo nginx; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "port held by another program stops the task" "Port 8080 is used by nginx" "$(cat "$TMP/err")"
assert_ok "port held: Docker was not touched" test ! -e "$TMP/reached"
( DENWATCHER_PORT=8080 DENWATCHER_STATUS_PORT=9443 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { [[ "$1" == 9443 ]] && echo caddy; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "status port held by another program stops the task" "Port 9443 is used by caddy; set DENWATCHER_STATUS_PORT" "$(cat "$TMP/err")"
assert_ok "status port held: Docker was not touched" test ! -e "$TMP/reached"
( DENWATCHER_PORT=8080 DENWATCHER_IMAGE=ghcr.io/x/y:main
  dpkg() { echo armhf; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "32-bit OS stops the task" "needs a 64-bit OS" "$(cat "$TMP/err")"
# Docker's proxy holds the port for some container: ours, or another's.
# shellcheck disable=SC2329 # called by denwatcher_port_container
have() { [[ "$1" == docker ]] || command -v "$1" >/dev/null 2>&1; }
# shellcheck disable=SC2329 # called by denwatcher_port_container
docker() {
  [[ "$1" == ps ]] || return 1
  printf '%s\n' 'teamspeak 0.0.0.0:9987->9987/udp, 0.0.0.0:10080->10080/tcp' \
    'den-watcher 0.0.0.0:9393->9393/tcp, [::]:9393->9393/tcp, 0.0.0.0:9443->9443/tcp' 'kiosk 0.0.0.0:19393->8080/tcp'
}
( DENWATCHER_PORT=10080 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "port published by another container stops the task" "Port 10080 is published by the teamspeak container; set DENWATCHER_PORT" "$(cat "$TMP/err")"
assert_ok "port published by another container: Docker was not touched" test ! -e "$TMP/reached"
( DENWATCHER_PORT=9393 DENWATCHER_STATUS_PORT=19393 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "status port published by another container stops the task" "Port 19393 is published by the kiosk container; set DENWATCHER_STATUS_PORT" "$(cat "$TMP/err")"
( DENWATCHER_PORT=9393 DENWATCHER_STATUS_PORT=9443 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_denwatcher ) >/dev/null 2>&1 || true
assert_ok "ports published by Den-Watcher itself go on to Docker" test -e "$TMP/reached"
rm -f "$TMP/reached"
( DENWATCHER_PORT=8080 DENWATCHER_IMAGE=ghcr.io/x/y:main
  docker() { return 1; }
  port_owner() { echo docker-proxy; }
  run_denwatcher ) >/dev/null 2>&1 || true
assert_ok "port held by Docker's proxy of no known container goes on to Docker" test -e "$TMP/reached"
unset -f container_require_docker port_owner dpkg docker
have() { command -v "$1" >/dev/null 2>&1; }

# --- the containers add-on --------------------------------------------------------
# The Pi's radios are faked too, as on: rfkill lists none, NetworkManager's
# is on; the system D-Bus is there.
# shellcheck disable=SC2329 # called by denwatcher_wifi_radio
rfkill() { :; }
# shellcheck disable=SC2329 # called by denwatcher_wifi_radio
nmcli() { echo enabled; }
denwatcher_system_dbus() { return 0; }
container_require_docker() { :; }
port_owner() { return 1; }
dpkg() { echo arm64; }
container_dir() { echo "$TMP/opt/$1"; }
container_pull() { echo pull >>"$TMP/calls"; }
container_up() { echo "$3" >"$TMP/recreate"; echo up >>"$TMP/calls"; }
container_wait_stable() { echo "$1" >>"$TMP/waited"; }
mkdir -p "$TMP/docker/containers"
docker() { [[ "$1" == info ]] && echo "$TMP/docker"; }
compose="$TMP/opt/denwatcher/docker-compose.yml"
( run_denwatcher ) >/dev/null 2>&1
assert_contains "containers: on by default" "source: \"$TMP/docker/containers\"" "$(cat "$compose")"
assert_contains "containers: add-on checked to stay up" "den-watcher-containers" "$(cat "$TMP/waited")"
( DENWATCHER_CONTAINERS=no; run_denwatcher ) >/dev/null 2>&1
assert_lacks "containers: off leaves the add-on out" "den-watcher-containers" "$(cat "$compose")"
( DENWATCHER_CONTAINERS=no DENWATCHER_ADDONS=none; run_denwatcher ) >/dev/null 2>&1
assert_lacks "addons: none and no containers leave the add-on volume out" "addons" "$(cat "$compose")"
( DENWATCHER_ADDONS='kernel, memory,kernel'; run_denwatcher ) >/dev/null 2>&1
assert_eq "addons: a list, each once" 2 "$(grep -c 'entrypoint: \["/den-watcher-\(kernel\|memory\)' "$compose")"
assert_lacks "addons: only those listed" "den-watcher-power" "$(cat "$compose")"
( run_denwatcher ) >/dev/null 2>"$TMP/err"
assert_contains "addons: all by default, each checked to stay up" "den-watcher-processes" "$(cat "$TMP/waited")"
assert_contains "addons: bluetooth with a system D-Bus" "den-watcher-bluetooth" "$(cat "$compose")"
assert_contains "addons: wifi with a system D-Bus" "den-watcher-wifi" "$(cat "$compose")"
assert_lacks "addons: nothing left out with a system D-Bus" "is left out" "$(cat "$TMP/err")"
# shellcheck disable=SC2329 # called by run_denwatcher
( denwatcher_system_dbus() { return 1; }; run_denwatcher ) >/dev/null 2>"$TMP/err"
assert_lacks "addons: no system D-Bus leaves bluetooth out" "den-watcher-bluetooth" "$(cat "$compose")"
assert_contains "addons: and says so" "bluetooth add-on is left out" "$(cat "$TMP/err")"
assert_lacks "addons: no system D-Bus leaves wifi out" "den-watcher-wifi" "$(cat "$compose")"
assert_contains "addons: and says so for wifi" "wifi add-on is left out" "$(cat "$TMP/err")"
assert_contains "addons: the others stay" "den-watcher-processes" "$(cat "$compose")"
# The last add-on left out is not an error (grep finds nothing to keep).
# Run outside a condition, where errexit is in force as in setup.sh.
rm -f "$TMP/calls"
set +e
# shellcheck disable=SC2329 # called by run_denwatcher
( set -e; DENWATCHER_ADDONS=wifi DENWATCHER_CONTAINERS=no; denwatcher_system_dbus() { return 1; }; run_denwatcher ) >/dev/null 2>"$TMP/err"
status=$?
set -e
assert_eq "addons: no system D-Bus with wifi as the only add-on goes on (stderr: $(cat "$TMP/err"))" 0 "$status"
assert_lacks "addons: and leaves the add-on volume out" "addons:/addons" "$(cat "$compose")"
assert_contains "addons: and starts Den-Watcher" "up" "$(cat "$TMP/calls")"
rm -f "$TMP/calls"
# shellcheck disable=SC2329 # called by run_denwatcher
( DENWATCHER_ADDONS=kernel,wifi DENWATCHER_WIFI_COUNTRY=at
  denwatcher_wifi_radio() { echo "radio $1" >>"$TMP/calls"; }
  run_denwatcher ) >/dev/null 2>&1
assert_eq "radio: switched on with the wifi add-on, in the country upper-cased, after the pull" $'pull\nradio AT\nup' "$(cat "$TMP/calls")"
rm -f "$TMP/calls"
# shellcheck disable=SC2329 # called by run_denwatcher
( DENWATCHER_ADDONS=kernel,wifi DENWATCHER_WIFI_RADIO=no
  denwatcher_wifi_radio() { echo "radio $1" >>"$TMP/calls"; }
  run_denwatcher ) >/dev/null 2>&1
assert_lacks "radio: DENWATCHER_WIFI_RADIO=no leaves it as it is" "radio" "$(cat "$TMP/calls")"
rm -f "$TMP/calls"
# shellcheck disable=SC2329 # called by run_denwatcher
( DENWATCHER_ADDONS=kernel
  denwatcher_wifi_radio() { echo "radio $1" >>"$TMP/calls"; }
  run_denwatcher ) >/dev/null 2>&1
assert_lacks "radio: left as it is without the wifi add-on" "radio" "$(cat "$TMP/calls")"
rm -f "$TMP/calls"
# shellcheck disable=SC2329 # called by run_denwatcher
( DENWATCHER_ADDONS=kernel,wifi
  denwatcher_system_dbus() { return 1; }
  denwatcher_wifi_radio() { echo "radio $1" >>"$TMP/calls"; }
  run_denwatcher ) >/dev/null 2>&1
assert_lacks "radio: left as it is when the wifi add-on is left out" "radio" "$(cat "$TMP/calls")"
# A pull that fails changes nothing on the Pi: no radio, no passwords file.
rm -f "$TMP/calls" "$TMP/opt/denwatcher/router-secrets/router-passwords"
# shellcheck disable=SC2329 # called by run_denwatcher
( DENWATCHER_ADDONS=wifi DENWATCHER_ROUTER_PASSWORD='Box=secret'
  container_pull() { echo pull >>"$TMP/calls"; exit 1; }
  denwatcher_wifi_radio() { echo "radio $1" >>"$TMP/calls"; }
  save_secret() { :; }
  run_denwatcher ) >/dev/null 2>&1 || true
assert_eq "pull fails: the radio is left as it is and nothing starts" pull "$(cat "$TMP/calls")"
assert_ok "pull fails: no passwords file" test ! -e "$TMP/opt/denwatcher/router-secrets/router-passwords"
rm -f "$TMP/calls"
# shellcheck disable=SC2329 # called by run_denwatcher
docker() { [[ "$1" == info ]] && echo "$TMP/nodocker"; }
( run_denwatcher ) >/dev/null 2>"$TMP/err"
assert_lacks "containers: no Docker folder leaves the add-on out" "den-watcher-containers" "$(cat "$compose")"
assert_contains "containers: no Docker folder warns" "containers add-on is left out" "$(cat "$TMP/err")"
# shellcheck disable=SC2329 # called by run_denwatcher
docker() { [[ "$1" == info ]] && echo "/var/lib/do\$cker"; }
( run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "containers: odd Docker folder stops the task" "set DENWATCHER_CONTAINERS=no" "$(cat "$TMP/err")"
# shellcheck disable=SC2329 # called by run_denwatcher
docker() { [[ "$1" == info ]] && echo "$TMP/docker"; }

# --- the Wi-Fi radio ---------------------------------------------------------------
# The tools are faked and record their calls with the locale they ran in;
# $no_tools names the ones "not installed". A Pi on cable as Raspberry Pi OS
# leaves it: no country (iw says 00), the radio soft-blocked, NetworkManager's
# Wi-Fi off.
denwatcher_rfkill_dir="$TMP/rfkill"
denwatcher_country_unset="$TMP/wifi-country-unset"
mkdir -p "$denwatcher_rfkill_dir"
no_tools=""
# shellcheck disable=SC2329 # called by the task
have() { [[ " $no_tools " != *" $1 "* ]] && command -v "$1" >/dev/null 2>&1; }
radio_state=$'0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: no'
reg_state=00
nm_state=disabled
raspi_ok=0 iw_ok=0 nm_ok=0 rfkill_ok=0
# shellcheck disable=SC2329 # called by the task
rfkill() { echo "rfkill $* (${LC_ALL:-})" >>"$TMP/radio-calls"; [[ "$1" != list ]] || echo "$radio_state"; return "$rfkill_ok"; }
# shellcheck disable=SC2329 # called by the task
nmcli() { echo "nmcli $* (${LC_ALL:-})" >>"$TMP/radio-calls"; [[ "$*" != "radio wifi" ]] || echo "$nm_state"; return "$nm_ok"; }
# shellcheck disable=SC2329 # called by the task
raspi-config() { echo "raspi-config $*" >>"$TMP/radio-calls"; return "$raspi_ok"; }
# shellcheck disable=SC2329 # called by the task
iw() {
  echo "iw $* (${LC_ALL:-})" >>"$TMP/radio-calls"
  [[ "$*" != "reg get" ]] || printf 'global\ncountry %s: DFS-UNSET\n\t(2402 - 2472 @ 40), (N/A, 20), (N/A)\n\n' "$reg_state"
  [[ "$*" != "reg set "* ]] || return "$iw_ok"
}
radio() { rm -f "$TMP/radio-calls"; : >"$TMP/radio-calls"; echo 1 >"$denwatcher_rfkill_dir/platform-fe300000.mmcnr:wlan"; denwatcher_wifi_radio "$@" >"$TMP/out" 2>"$TMP/err"; calls="$(cat "$TMP/radio-calls")"; }
radio DE
assert_contains "radio: asks rfkill in English" "rfkill list wlan (C)" "$calls"
assert_contains "radio: asks NetworkManager in English" "nmcli radio wifi (C)" "$calls"
assert_contains "radio: asks iw in English" "iw reg get (C)" "$calls"
assert_contains "radio: sets the country with raspi-config" "raspi-config nonint do_wifi_country DE" "$calls"
assert_lacks "radio: and not with iw" "iw reg set" "$calls"
assert_contains "radio: unblocks the radio" "rfkill unblock 0" "$calls"
assert_contains "radio: switches it on in NetworkManager" "nmcli radio wifi on" "$calls"
assert_eq "radio: unblocked for the next boots too" 0 "$(cat "$denwatcher_rfkill_dir/platform-fe300000.mmcnr:wlan")"
assert_contains "radio: says so" "Switched the Wi-Fi radio on (country DE)" "$(cat "$TMP/out")"
assert_eq "radio: without a warning" "" "$(cat "$TMP/err")"
# Someone set a country and switched the radio off: it stays off.
reg_state=DE
radio AT
assert_lacks "radio: a country set is kept" "do_wifi_country" "$calls"
assert_lacks "radio: and the radio stays off" "unblock" "$calls"
assert_lacks "radio: in NetworkManager too" "nmcli radio wifi on" "$calls"
assert_eq "radio: and for the next boots" 1 "$(cat "$denwatcher_rfkill_dir/platform-fe300000.mmcnr:wlan")"
assert_contains "radio: says why and how" "Wi-Fi country DE is set, so it stays off" "$(cat "$TMP/out")"
assert_lacks "radio: not as switched on" "Switched" "$(cat "$TMP/out")"
# Without iw: the marker file of Raspberry Pi OS tells, else nothing is changed.
no_tools="iw"
radio DE
assert_lacks "radio: no iw and no marker: unknown country, left as it is" "unblock" "$calls"
assert_contains "radio: and says so" "cannot be told" "$(cat "$TMP/out")"
touch "$denwatcher_country_unset"
radio DE
assert_contains "radio: no iw, the marker says no country: switched on" "Switched the Wi-Fi radio on (country DE)" "$(cat "$TMP/out")"
rm -f "$denwatcher_country_unset"
no_tools=""
reg_state=00
# Radio on already: nothing is done.
radio_state=$'0: phy0: Wireless LAN\n\tSoft blocked: no\n\tHard blocked: no'
nm_state=enabled
radio DE
assert_lacks "radio: on already, left as it is" "raspi-config" "$calls"
assert_lacks "radio: on already, not asked for the country" "iw reg get" "$calls"
assert_eq "radio: on already, nothing said" "" "$(cat "$TMP/out")$(cat "$TMP/err")"
# NetworkManager's Wi-Fi off is enough to go on; rfkill not blocked: no unblock.
nm_state=disabled
radio DE
assert_contains "radio: NetworkManager off alone switches it on" "nmcli radio wifi on" "$calls"
assert_lacks "radio: and unblocks nothing" "unblock" "$calls"
# Two radios: the onboard one behind a hardware switch, a USB one soft-blocked.
radio_state=$'0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: yes\n1: phy1: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: no'
radio DE
assert_contains "radio: a hardware switch warns, naming the radio" "radio phy0 is switched off by a hardware switch" "$(cat "$TMP/err")"
assert_contains "radio: and the other radio is unblocked" "rfkill unblock 1" "$calls"
assert_lacks "radio: not the one behind the switch" "rfkill unblock 0" "$calls"
assert_contains "radio: and switched on" "Switched the Wi-Fi radio on" "$(cat "$TMP/out")"
radio_state=$'0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: yes'
nm_state=enabled
radio DE
assert_contains "radio: only a hardware switch warns" "hardware switch" "$(cat "$TMP/err")"
assert_lacks "radio: and changes nothing" "unblock" "$calls"
assert_lacks "radio: not the country either" "do_wifi_country" "$calls"
# raspi-config fails: iw sets the country for this boot, with a warning.
radio_state=$'0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: no'
nm_state=disabled
raspi_ok=1
radio DE
assert_contains "radio: raspi-config failing warns" "raspi-config could not set the Wi-Fi country DE" "$(cat "$TMP/err")"
assert_contains "radio: and iw sets it for this boot" "iw reg set DE" "$calls"
assert_contains "radio: with a warning that it is not kept" "for this boot only" "$(cat "$TMP/err")"
assert_contains "radio: and the radio is switched on" "Switched the Wi-Fi radio on (country DE)" "$(cat "$TMP/out")"
# No raspi-config (not Raspberry Pi OS) and iw fails: nothing is unblocked.
no_tools="raspi-config"
iw_ok=1
radio DE
assert_lacks "radio: no raspi-config: no warning about it" "raspi-config" "$(cat "$TMP/err")"
assert_contains "radio: iw failing too warns" "Could not set the Wi-Fi country DE" "$(cat "$TMP/err")"
assert_lacks "radio: and the radio stays off" "unblock" "$calls"
assert_lacks "radio: not switched on" "Switched" "$(cat "$TMP/out")"
no_tools=""
iw_ok=0 raspi_ok=0
# NetworkManager refuses: a warning, not a success.
nm_ok=1
radio DE
assert_contains "radio: NetworkManager failing warns" "NetworkManager did not switch the Wi-Fi radio on" "$(cat "$TMP/err")"
assert_contains "radio: and the end says so" "The Wi-Fi radio is not on" "$(cat "$TMP/err")"
assert_lacks "radio: not as switched on" "Switched" "$(cat "$TMP/out")"
nm_ok=0
# rfkill refuses: the same.
rfkill_ok=1
radio DE
assert_contains "radio: rfkill failing warns" "rfkill could not unblock Wi-Fi radio 0" "$(cat "$TMP/err")"
assert_lacks "radio: rfkill failing is no success" "Switched" "$(cat "$TMP/out")"
rfkill_ok=0
unset -f raspi-config iw radio
have() { command -v "$1" >/dev/null 2>&1; }
# shellcheck disable=SC2329 # called by denwatcher_wifi_radio
rfkill() { :; }
# shellcheck disable=SC2329 # called by denwatcher_wifi_radio
nmcli() { echo enabled; }

# --- the router passwords file ---------------------------------------------------
chown() { echo "$1" >"$TMP/owner"; }
save_secret() { printf '%s=%s\n' "$2" "$3" >"$TMP/saved"; }
load_secret() { sed -nE "s/^$2=//p" "$TMP/saved" 2>/dev/null | grep . ; }
secrets="$TMP/opt/denwatcher/router-secrets/router-passwords"
( DENWATCHER_ROUTERS='Box=fritzbox:monitor@192.168.178.1,Core=snmpv3:monitor@192.168.1.3'
  DENWATCHER_ROUTER_PASSWORD='Box=pa=ss word,Core=other'
  run_denwatcher ) >/dev/null 2>&1
assert_eq "passwords: one name=password per line" $'Box=pa=ss word\nCore=other' "$(cat "$secrets")"
assert_eq "passwords: readable by the owner only" 400 "$(stat -c %a "$secrets")"
assert_eq "passwords: owned by the container's user" 65532:65532 "$(cat "$TMP/owner")"
assert_eq "passwords: new file restarts the container" 1 "$(cat "$TMP/recreate")"
assert_contains "passwords: kept for the next runs" "DENWATCHER_ROUTER_PASSWORD=Box=pa=ss word,Core=other" "$(cat "$TMP/saved")"
( DENWATCHER_ROUTERS='Box=fritzbox:monitor@192.168.178.1'; run_denwatcher ) >/dev/null 2>&1
assert_eq "passwords: kept from an earlier run" $'Box=pa=ss word\nCore=other' "$(cat "$secrets")"
assert_eq "passwords: unchanged file keeps the container" 0 "$(cat "$TMP/recreate")"
rm -f "$TMP/saved"
( run_denwatcher ) >/dev/null 2>&1
assert_ok "passwords: none removes the file" test ! -e "$secrets"
assert_eq "passwords: removed file restarts the container" 1 "$(cat "$TMP/recreate")"

# --- moving an install from before the rename ------------------------------------
# A Pi with the usagecontrol task: /opt/usagecontrol, its kept router password
# and the volume usagecontrol_data. Docker is faked: each volume's folder is
# $TMP/vol/<name>, and compose create makes the new one.
rm -rf "$TMP/opt" "$TMP/vol"
mkdir -p "$TMP/opt/usagecontrol/router-secrets" "$TMP/vol/usagecontrol_data"
touch "$TMP/opt/usagecontrol/docker-compose.yml"
echo history >"$TMP/vol/usagecontrol_data/usage-control.db"
printf 'USAGECONTROL_ROUTER_PASSWORD=Box=old\n' >"$TMP/saved-usagecontrol"
save_secret() { printf '%s=%s\n' "$2" "$3" >"$TMP/saved-$1"; }
load_secret() { sed -nE "s/^$2=//p" "$TMP/saved-$1" 2>/dev/null | grep . ; }
# shellcheck disable=SC2329 # called by run_denwatcher
docker() {
  echo "$*" >>"$TMP/docker-calls"
  case "$1 $2" in
    "info "*) echo "$TMP/docker" ;;
    "compose -f") [[ "$4" != create ]] || mkdir -p "$TMP/vol/denwatcher_data" ;;
    "volume inspect")
      if [[ "$3" == -f ]]; then echo "$TMP/vol/$5"; else test -d "$TMP/vol/$3"; fi ;;
    "volume rm") rm -rf "${TMP:?}/vol/$3" ;;
  esac
}
# A failure before the copy leaves the old install running.
# shellcheck disable=SC2329 # called by run_denwatcher
( docker() { [[ "$1 $2 ${4:-}" != "compose -f create" ]] || return 1; echo "$*" >>"$TMP/docker-calls"; case "$1 $2" in "info "*) echo "$TMP/docker" ;; "volume inspect") test -d "$TMP/vol/$3" ;; esac; }
  run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "move: a failed create stops the task" "Could not create the den-watcher container" "$(cat "$TMP/err")"
assert_lacks "move: and leaves the old install running" "usagecontrol/docker-compose.yml" "$(cat "$TMP/docker-calls")"
assert_ok "move: and keeps the old folder" test -f "$TMP/opt/usagecontrol/docker-compose.yml"
rm -f "$TMP/docker-calls"
# A failed copy starts the old install again and leaves the new volume empty.
# shellcheck disable=SC2329 # called by run_denwatcher
( cp() { return 1; }; run_denwatcher ) >/dev/null 2>"$TMP/err" || true
assert_contains "move: a failed copy stops the task" "the old install is running again" "$(cat "$TMP/err")"
assert_contains "move: and starts the old install again" "compose -f $TMP/opt/usagecontrol/docker-compose.yml start" "$(cat "$TMP/docker-calls")"
assert_lacks "move: and does not remove it" "usagecontrol/docker-compose.yml down" "$(cat "$TMP/docker-calls")"
assert_eq "move: and leaves the new volume empty for the next run" "" "$(ls -A "$TMP/vol/denwatcher_data")"
rm -f "$TMP/docker-calls"
( run_denwatcher ) >"$TMP/err" 2>&1
calls="$(cat "$TMP/docker-calls")"
assert_contains "move: Compose creates the new volume" "compose -f $TMP/opt/denwatcher/docker-compose.yml create den-watcher" "$calls"
assert_contains "move: stops the old containers" "compose -f $TMP/opt/usagecontrol/docker-compose.yml stop" "$calls"
assert_contains "move: removes the old containers" "compose -f $TMP/opt/usagecontrol/docker-compose.yml down" "$calls"
assert_eq "move: the new volume first, the old install stopped for the copy and removed last" \
  $'create\nstop\ndown' "$(grep -oE ' (create|stop|down)' <<<"$calls" | tr -d ' ')"
assert_eq "move: copies the history" history "$(cat "$TMP/vol/denwatcher_data/usage-control.db")"
assert_ok "move: keeps the old volume as a backup" test -f "$TMP/vol/usagecontrol_data/usage-control.db"
assert_contains "move: says how to remove the backup" "docker volume rm usagecontrol_data" "$(cat "$TMP/err")"
assert_ok "move: removes the old folder" test ! -e "$TMP/opt/usagecontrol"
assert_eq "move: keeps the router password" "Box=old" "$(cat "$TMP/opt/denwatcher/router-secrets/router-passwords")"
assert_contains "move: under the new name" "DENWATCHER_ROUTER_PASSWORD=Box=old" "$(cat "$TMP/saved-denwatcher")"
rm -f "$TMP/docker-calls"
( run_denwatcher ) >/dev/null 2>&1
assert_lacks "move: only once" "down" "$(cat "$TMP/docker-calls")"
# A move cut short after the copy: the new volume is kept, not copied over.
mkdir -p "$TMP/opt/usagecontrol"; touch "$TMP/opt/usagecontrol/docker-compose.yml"
echo newer >"$TMP/vol/denwatcher_data/usage-control.db"
( run_denwatcher ) >/dev/null 2>&1
assert_eq "move: a history in the new volume is kept" newer "$(cat "$TMP/vol/denwatcher_data/usage-control.db")"
assert_ok "move: then removes the old folder" test ! -e "$TMP/opt/usagecontrol"
unset -f container_require_docker port_owner dpkg container_dir container_pull container_up container_wait_stable docker chown save_secret load_secret rfkill nmcli

finish_tests
