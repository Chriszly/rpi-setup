#!/usr/bin/env bash
# test-task-usagecontrol.sh - unit tests for tasks/usagecontrol.sh: the
# compose file it writes, and the checks that stop it before anything changes.
#
# Run: bash ci/test-task-usagecontrol.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/usagecontrol.sh"

# --- the compose file -----------------------------------------------------------
out="$(usagecontrol_compose ghcr.io/chriszly/usage-control:1.2.3 8090)"
assert_contains "compose: image" 'image: "ghcr.io/chriszly/usage-control:1.2.3"' "$out"
assert_contains "compose: port on the host" '"0.0.0.0:8090:9393"' "$out"
assert_contains "compose: port the page is reachable on" 'PUBLIC_PORT: "8090"' "$out"
assert_contains "compose: history kept in a volume" "data:/data" "$out"
assert_contains "compose: host /proc read-only" "/proc:/host/proc:ro" "$out"
assert_contains "compose: host /sys read-only" "/sys:/host/sys:ro" "$out"
assert_contains "compose: no capabilities" "- ALL" "$out"
assert_contains "compose: read-only file system" "read_only: true" "$out"
assert_contains "compose: no routers by default" 'HUB_ROUTERS: ""' "$out"
assert_contains "compose: router passwords mounted read-only" "./router-secrets:/run/secrets:ro" "$out"
out="$(usagecontrol_compose ghcr.io/chriszly/usage-control:1.2.3 8090 'Router=upnp:192.168.1.1,Box=fritzbox:monitor@192.168.178.1')"
assert_contains "compose: routers" 'HUB_ROUTERS: "Router=upnp:192.168.1.1,Box=fritzbox:monitor@192.168.178.1"' "$out"
assert_lacks "compose: no containers add-on without Docker's folder" "usage-control-containers" "$out"
assert_lacks "compose: no add-on folder without the add-on" "addons" "$out"
with="$(usagecontrol_compose ghcr.io/chriszly/usage-control:1.2.3 8090 '' /srv/docker)"
assert_contains "containers: add-on service" "entrypoint: [\"/usage-control-containers\"]" "$with"
assert_contains "containers: same image" $'usage-control-containers:\n    image: "ghcr.io/chriszly/usage-control:1.2.3"' "$with"
assert_contains "containers: names from Docker's folder" 'source: "/srv/docker/containers"' "$with"
assert_contains "containers: cgroups read-only" "/sys/fs/cgroup:/host/sys/fs/cgroup:ro" "$with"
assert_contains "containers: no network" "network_mode: none" "$with"
assert_lacks "containers: never the Docker socket" "docker.sock" "$with"
assert_contains "containers: website reads the add-on folder" "ADDONS_DIR: /addons" "$with"
assert_contains "containers: website mounts it read-only" "addons:/addons:ro" "$with"
assert_contains "containers: add-on folder in memory" "type: tmpfs" "$with"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  printf '%s\n' "$out" >"$TMP/docker-compose.yml"
  assert_ok "compose: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
  printf '%s\n' "$with" >"$TMP/docker-compose.yml"
  assert_ok "containers: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
else
  skip "compose: docker compose not installed"
fi

# --- settings are checked before anything changes ------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
port_owner() { return 1; }
dpkg() { echo arm64; }
( USAGECONTROL_PORT=70000; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad port stops the task" "USAGECONTROL_PORT" "$(cat "$TMP/err")"
( USAGECONTROL_IMAGE='Bad Image'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad image stops the task" "USAGECONTROL_IMAGE must be a Docker image" "$(cat "$TMP/err")"
( USAGECONTROL_ROUTERS='Router=upnp:192.168.1.1"'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "router with a quote stops the task" "USAGECONTROL_ROUTERS must be" "$(cat "$TMP/err")"
# shellcheck disable=SC2016 # a literal $, as compose would expand it
( USAGECONTROL_ROUTERS='Router=upnp:$HOME'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "router with a \$ stops the task" "USAGECONTROL_ROUTERS must be" "$(cat "$TMP/err")"
( USAGECONTROL_ROUTER_PASSWORD='hunter2'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "password without a name stops the task" "USAGECONTROL_ROUTER_PASSWORD must be" "$(cat "$TMP/err")"
assert_lacks "password is not shown" "hunter2" "$(cat "$TMP/err")"
( USAGECONTROL_ROUTER_PASSWORD='Box=a,=b'; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "second password without a name stops the task" "USAGECONTROL_ROUTER_PASSWORD must be" "$(cat "$TMP/err")"
( USAGECONTROL_CONTAINERS=maybe; run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad containers setting stops the task" "USAGECONTROL_CONTAINERS must be yes or no" "$(cat "$TMP/err")"
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  port_owner() { echo nginx; }
  run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "port held by another program stops the task" "Port 8080 is used by nginx" "$(cat "$TMP/err")"
assert_ok "port held: Docker was not touched" test ! -e "$TMP/reached"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  dpkg() { echo armhf; }
  run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "32-bit OS stops the task" "needs a 64-bit OS" "$(cat "$TMP/err")"
( USAGECONTROL_PORT=8080 USAGECONTROL_IMAGE=ghcr.io/x/y:main
  port_owner() { echo docker-proxy; }
  run_usagecontrol ) >/dev/null 2>&1 || true
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
compose="$TMP/opt/usagecontrol/docker-compose.yml"
( run_usagecontrol ) >/dev/null 2>&1
assert_contains "containers: on by default" "source: \"$TMP/docker/containers\"" "$(cat "$compose")"
assert_contains "containers: add-on checked to stay up" "usage-control-containers" "$(cat "$TMP/waited")"
( USAGECONTROL_CONTAINERS=no; run_usagecontrol ) >/dev/null 2>&1
assert_lacks "containers: off leaves the add-on out" "usage-control-containers" "$(cat "$compose")"
# shellcheck disable=SC2329 # called by run_usagecontrol
docker() { [[ "$1" == info ]] && echo "$TMP/nodocker"; }
( run_usagecontrol ) >/dev/null 2>"$TMP/err"
assert_lacks "containers: no Docker folder leaves the add-on out" "usage-control-containers" "$(cat "$compose")"
assert_contains "containers: no Docker folder warns" "containers add-on is left out" "$(cat "$TMP/err")"
# shellcheck disable=SC2329 # called by run_usagecontrol
docker() { [[ "$1" == info ]] && echo "/var/lib/do\$cker"; }
( run_usagecontrol ) >/dev/null 2>"$TMP/err" || true
assert_contains "containers: odd Docker folder stops the task" "set USAGECONTROL_CONTAINERS=no" "$(cat "$TMP/err")"
# shellcheck disable=SC2329 # called by run_usagecontrol
docker() { [[ "$1" == info ]] && echo "$TMP/docker"; }

# --- the router passwords file ---------------------------------------------------
chown() { echo "$1" >"$TMP/owner"; }
save_secret() { printf '%s=%s\n' "$2" "$3" >"$TMP/saved"; }
load_secret() { sed -nE "s/^$2=//p" "$TMP/saved" 2>/dev/null | grep . ; }
secrets="$TMP/opt/usagecontrol/router-secrets/router-passwords"
( USAGECONTROL_ROUTERS='Box=fritzbox:monitor@192.168.178.1,Core=snmpv3:monitor@192.168.1.3'
  USAGECONTROL_ROUTER_PASSWORD='Box=pa=ss word,Core=other'
  run_usagecontrol ) >/dev/null 2>&1
assert_eq "passwords: one name=password per line" $'Box=pa=ss word\nCore=other' "$(cat "$secrets")"
assert_eq "passwords: readable by the owner only" 400 "$(stat -c %a "$secrets")"
assert_eq "passwords: owned by the container's user" 65532:65532 "$(cat "$TMP/owner")"
assert_eq "passwords: new file restarts the container" 1 "$(cat "$TMP/recreate")"
assert_contains "passwords: kept for the next runs" "USAGECONTROL_ROUTER_PASSWORD=Box=pa=ss word,Core=other" "$(cat "$TMP/saved")"
( USAGECONTROL_ROUTERS='Box=fritzbox:monitor@192.168.178.1'; run_usagecontrol ) >/dev/null 2>&1
assert_eq "passwords: kept from an earlier run" $'Box=pa=ss word\nCore=other' "$(cat "$secrets")"
assert_eq "passwords: unchanged file keeps the container" 0 "$(cat "$TMP/recreate")"
rm -f "$TMP/saved"
( run_usagecontrol ) >/dev/null 2>&1
assert_ok "passwords: none removes the file" test ! -e "$secrets"
assert_eq "passwords: removed file restarts the container" 1 "$(cat "$TMP/recreate")"
unset -f container_require_docker port_owner dpkg container_dir container_pull container_up container_wait_stable docker chown save_secret load_secret

finish_tests
