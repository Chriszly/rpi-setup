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
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
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
( DENWATCHER_PORT=8080 DENWATCHER_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_denwatcher ) >/dev/null 2>&1 || true
assert_ok "port held by Docker's proxy goes on to Docker" test -e "$TMP/reached"
unset -f container_require_docker port_owner dpkg

# --- the containers add-on --------------------------------------------------------
container_require_docker() { :; }
port_owner() { return 1; }
dpkg() { echo arm64; }
container_dir() { echo "$TMP/opt/$1"; }
container_pull() { :; }
container_up() { echo "$3" >"$TMP/recreate"; }
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
( run_denwatcher ) >/dev/null 2>&1
assert_contains "addons: all by default, each checked to stay up" "den-watcher-processes" "$(cat "$TMP/waited")"
if [[ -S /run/dbus/system_bus_socket ]]; then
  assert_contains "addons: bluetooth with a system D-Bus" "den-watcher-bluetooth" "$(cat "$compose")"
else
  ( run_denwatcher ) >/dev/null 2>"$TMP/err"
  assert_lacks "addons: no system D-Bus leaves bluetooth out" "den-watcher-bluetooth" "$(cat "$compose")"
  assert_contains "addons: and says so" "bluetooth add-on is left out" "$(cat "$TMP/err")"
fi
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
( run_denwatcher ) >"$TMP/err" 2>&1
calls="$(cat "$TMP/docker-calls")"
assert_contains "move: stops the old containers" "compose -f $TMP/opt/usagecontrol/docker-compose.yml down" "$calls"
assert_contains "move: Compose creates the new volume" "compose -f $TMP/opt/denwatcher/docker-compose.yml create den-watcher" "$calls"
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
unset -f container_require_docker port_owner dpkg container_dir container_pull container_up container_wait_stable docker chown save_secret load_secret

finish_tests
