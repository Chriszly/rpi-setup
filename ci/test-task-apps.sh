#!/usr/bin/env bash
# test-task-apps.sh - unit tests for tasks/apps.sh: the APPS_LIST entries it
# accepts, the compose file it writes, and the checks that stop it before
# anything changes.
#
# Run: bash ci/test-task-apps.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/apps.sh"

# --- APPS_LIST ------------------------------------------------------------------
assert_eq "list: one app, container port 8080 by default" "game 8091 8080 ghcr.io/you/game:latest" \
  "$(apps_parse 'game:8091=ghcr.io/you/game:latest')"
assert_eq "list: own container port, commas and spaces" $'game 8091 80 ghcr.io/you/game:1.2\nsite 8092 8080 you/site' \
  "$(apps_parse 'game:8091:80=ghcr.io/you/game:1.2, site:8092=you/site')"
assert_eq "list: empty" "" "$(apps_parse '')"
digest=ghcr.io/you/game@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
assert_eq "list: image by digest" "game 8091 8080 $digest" "$(apps_parse "game:8091=$digest")"
# shellcheck disable=SC2016 # a literal $, as compose would expand it
for bad in 'game=ghcr.io/you/game' 'Game:8091=you/game' 'game:8091=' 'game:70000=you/game' \
  'game:8091:0=you/game' 'game:8091=You/Game' 'game:8091=you/game"' 'game:8091=you/$HOME' \
  'game:8091=a game:8091=b' 'a:8091=x b:8091=y'; do
  assert_fails "list: '$bad' refused" apps_parse "$bad"
  ( apps_parse "$bad" ) >/dev/null 2>"$TMP/err" || true
  assert_contains "list: '$bad' named in the error" "APPS_LIST" "$(cat "$TMP/err")"
done

# --- the compose file -----------------------------------------------------------
out="$(apps_parse 'game:8091=ghcr.io/you/game:latest site:8092:80=you/site' | apps_compose 1234)"
assert_contains "compose: image" 'image: "ghcr.io/you/game:latest"' "$out"
assert_contains "compose: container named after the app" "container_name: game" "$out"
assert_contains "compose: port on the host" '"0.0.0.0:8091:8080"' "$out"
assert_contains "compose: own container port" '"0.0.0.0:8092:80"' "$out"
assert_contains "compose: card name" 'rpi-setup.link.name: "site"' "$out"
assert_contains "compose: card links to the port on the host" 'rpi-setup.link.port: "8092"' "$out"
assert_contains "compose: card description" 'rpi-setup.link.description: "App from you/site"' "$out"
assert_eq "compose: every app as the task's user" 2 "$(grep -c 'user: "1234:1234"' <<<"$out")"
assert_eq "compose: every app read-only" 2 "$(grep -c 'read_only: true' <<<"$out")"
assert_eq "compose: every app without capabilities" 2 "$(grep -c -- '- ALL' <<<"$out")"
assert_eq "compose: every app without new privileges" 2 "$(grep -c 'no-new-privileges:true' <<<"$out")"
assert_contains "compose: /tmp in memory, owned by the user" "/tmp:mode=1700,uid=1234,gid=1234" "$out"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  printf '%s\n' "$out" >"$TMP/docker-compose.yml"
  assert_ok "compose: docker compose accepts it" docker compose -f "$TMP/docker-compose.yml" config -q
else
  skip "compose: docker compose not installed"
fi

# --- settings are checked before anything changes ------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
container_dir() { echo "$TMP/opt/$1"; }
port_owner() { return 1; }
dpkg() { echo arm64; }
( APPS_LIST='game:8091'; run_apps ) >/dev/null 2>"$TMP/err" || true
assert_contains "bad entry stops the task" "APPS_LIST entries must look like name:port=image" "$(cat "$TMP/err")"
( APPS_LIST=''; run_apps ) >/dev/null 2>"$TMP/err" || true
assert_contains "no apps and none running stops the task" "APPS_LIST is empty" "$(cat "$TMP/err")"
( APPS_LIST='game:8091=you/game'
  port_owner() { echo nginx; }
  run_apps ) >/dev/null 2>"$TMP/err" || true
assert_contains "port held by another program stops the task" "Port 8091 of 'game' is used by nginx" "$(cat "$TMP/err")"
( APPS_LIST='game:8091=you/game'
  dpkg() { echo armhf; }
  run_apps ) >/dev/null 2>"$TMP/err" || true
assert_contains "32-bit OS stops the task" "Containers need a 64-bit OS" "$(cat "$TMP/err")"
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
( APPS_LIST='game:8091=you/game'
  port_owner() { echo docker-proxy; }
  run_apps ) >/dev/null 2>&1 || true
assert_ok "port held by Docker's proxy goes on to Docker" test -e "$TMP/reached"
unset -f container_require_docker port_owner dpkg

# --- a run ------------------------------------------------------------------------
container_require_docker() { :; }
port_owner() { return 1; }
dpkg() { echo arm64; }
assign_uid() { echo 1234; }
container_pull() { echo pull >>"$TMP/calls"; }
container_up() { echo "up $2" >>"$TMP/calls"; }
container_wait_stable() { echo "wait $1" >>"$TMP/calls"; }
docker() { echo "docker $*" >>"$TMP/calls"; }
compose="$TMP/opt/apps/docker-compose.yml"
( APPS_LIST='game:8091=you/game,site:8092=you/site'; run_apps ) >/dev/null 2>&1
assert_contains "run: compose file written" "container_name: site" "$(cat "$compose")"
assert_eq "run: pulled, started and every app checked to stay up" $'pull\nup game\nwait game\nwait site' "$(cat "$TMP/calls")"
: >"$TMP/calls"
( APPS_LIST=''; run_apps ) >/dev/null 2>&1
assert_contains "run: an emptied list takes the apps down" "down --remove-orphans" "$(cat "$TMP/calls")"
assert_ok "run: and puts the compose file aside" test ! -e "$compose" -a -e "$compose.disabled"

finish_tests
