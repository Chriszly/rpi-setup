#!/usr/bin/env bash
# test-containers.sh - tests for lib/containers.sh, the helpers behind
# <TASK>_DOCKER=yes. The Docker cases start small alpine containers and run
# only where a Docker daemon answers; the systemd cases need root and a booted
# systemd. Everything is created under a temporary folder and removed again.
#
# Run: bash ci/test-containers.sh   (sudo for the systemd cases)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/containers.sh"

export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
UNIT=rpi-setup-test-native
cleanup() {
    local c
    for c in $(docker ps -aq --filter name=^rpi-setup-test- 2>/dev/null); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    if [[ -f "/etc/systemd/system/$UNIT.service" ]]; then
        systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$UNIT.service"
        systemctl daemon-reload || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- container_dir --------------------------------------------------------------
assert_eq "container_dir follows RPI_SETUP_CONTAINER_ROOT" "$TMP/opt/web" "$(container_dir web)"
assert_eq "container_dir defaults to /opt" "/opt/web" "$(RPI_SETUP_CONTAINER_ROOT='' container_dir web)"

# --- the web container's compose file ----------------------------------------------
TASKS=()
. "$ROOT/tasks/web.sh"
head_out="$(WEB_IMAGE=nginx:stable-alpine web_container_compose /opt/web web)"
assert_contains "web compose names the image" '    image: "nginx:stable-alpine"' "$head_out"
assert_contains "web compose names the container" '    container_name: web' "$head_out"
assert_contains "web compose restarts unless stopped" 'restart: unless-stopped' "$head_out"
assert_contains "web compose blocks privilege escalation" 'no-new-privileges:true' "$head_out"
assert_contains "web compose drops every capability" $'cap_drop:\n      - ALL' "$head_out"
assert_contains "web compose adds only nginx's capabilities" \
    $'cap_add:\n      - CHOWN\n      - SETUID\n      - SETGID\n      - NET_BIND_SERVICE\n' "$head_out"

# --- container_write_secrets ----------------------------------------------------
sdir="$TMP/secrets"
assert_ok "write_secrets writes a new file" container_write_secrets "$sdir" 'A=1' 'B=two words'
assert_eq "secrets.env holds one line per value" $'A=1\nB=two words' "$(cat "$sdir/secrets.env")"
assert_eq "secrets.env is root-only" "600" "$(stat -c %a "$sdir/secrets.env")"
assert_fails "write_secrets reports no change for the same values" container_write_secrets "$sdir" 'A=1' 'B=two words'
assert_fails "write_secrets rejects a value without a name" container_write_secrets "$sdir" 'novalue'
assert_fails "write_secrets rejects a line break" container_write_secrets "$sdir" $'A=1\nB=2'

# --- container_copy_once ----------------------------------------------------------
mkdir -p "$TMP/native/sub"
echo hello >"$TMP/native/sub/file"
cdir="$TMP/opt/copy"
assert_ok "copy_once copies a native folder" container_copy_once "$cdir" "$TMP/native" "$cdir/data"
assert_eq "copy_once keeps sub folders" "hello" "$(cat "$cdir/data/sub/file" 2>/dev/null)"
echo changed >"$TMP/native/sub/file"
assert_fails "copy_once copies only once" container_copy_once "$cdir" "$TMP/native" "$cdir/data"
assert_eq "copy_once left the earlier copy alone" "hello" "$(cat "$cdir/data/sub/file")"
assert_fails "copy_once skips a missing folder" container_copy_once "$cdir" "$TMP/none" "$cdir/other"

# --- native units: stop, record, restore ------------------------------------------
if [[ $EUID -eq 0 ]] && [[ -d /run/systemd/system ]]; then
    printf '[Unit]\nDescription=rpi-setup test unit\n[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' \
        >"/etc/systemd/system/$UNIT.service"
    systemctl daemon-reload
    systemctl enable --now "$UNIT" >/dev/null 2>&1
    ndir="$TMP/opt/native"
    container_stop_native "$ndir" "$UNIT" no-such-unit-rpi-setup >/dev/null 2>&1
    assert_fails "stop_native stops the unit" systemctl is-active --quiet "$UNIT"
    assert_fails "stop_native disables the unit" systemctl is-enabled --quiet "$UNIT"
    assert_eq "stop_native records only installed units" "$UNIT" "$(cat "$ndir/.native-units")"
    container_restore_native "$ndir" >/dev/null 2>&1
    assert_ok "restore_native starts the unit again" systemctl is-active --quiet "$UNIT"
    assert_ok "restore_native enables the unit again" systemctl is-enabled --quiet "$UNIT"
    assert_eq "restore_native forgets the units" "no" "$([[ -e "$ndir/.native-units" ]] && echo yes || echo no)"
else
    skip "native unit cases need root and systemd"
fi

# --- container_wait_stable (container_state mocked, no waiting) --------------------
sleep() { :; }
container_state() { echo "running 0 ${MOCK_HEALTH:-none}"; }
assert_ok "wait_stable: a running container without a health check" container_wait_stable x 2 3
assert_ok "wait_stable: a healthy container" eval 'MOCK_HEALTH=healthy container_wait_stable x 2 3'
out="$( (MOCK_HEALTH=unhealthy container_wait_stable x 2 3) 2>&1)" && rc=0 || rc=$?
assert_eq "wait_stable fails for an unhealthy container" 1 "$rc"
assert_contains "wait_stable says the health check fails" "health check fails" "$out"
out="$( (MOCK_HEALTH=starting container_wait_stable x 2 3) 2>&1)" && rc=0 || rc=$?
assert_eq "wait_stable only warns while the health check is still starting" 0 "$rc"
assert_contains "wait_stable names the starting state" "still says 'starting'" "$out"
container_state() { echo "exited 0 none"; }
assert_fails "wait_stable fails for an exited container" container_wait_stable x 2 3
# The restart count goes up on every look.
: >"$TMP/restarts"
container_state() { echo x >>"$TMP/restarts"; echo "running $(wc -l <"$TMP/restarts") none"; }
assert_fails "wait_stable fails for a restarting container" container_wait_stable x 5 3
unset -f sleep container_state

# --- container_leave (docker mocked) ----------------------------------------------
# The mock logs its calls; MOCK_PS is what "compose ps -aq" prints (MOCK_PS_RC
# its status: 1 when the daemon is down) and MOCK_DOWN_RC what "compose down"
# returns.
leave_dir="$(container_dir leave)"
# shellcheck disable=SC2032 # a mock for this file; web.sh's xargs runs the real docker
docker() {
    printf '%s\n' "$*" >>"$TMP/docker.log"
    case "$1 ${4:-}" in
        "compose ps") printf '%s' "${MOCK_PS:-}"; return "${MOCK_PS_RC:-0}" ;;
        "compose down") return "${MOCK_DOWN_RC:-0}" ;;
    esac
}
install -d "$leave_dir/data"
echo old >"$leave_dir/docker-compose.yml"
: >"$TMP/docker.log"
MOCK_PS=abc123 container_leave leave >/dev/null 2>&1
assert_contains "leave takes the container down" "compose -f $leave_dir/docker-compose.yml down" "$(cat "$TMP/docker.log")"
assert_fails "leave removes the live compose file" test -e "$leave_dir/docker-compose.yml"
assert_eq "leave keeps it as docker-compose.yml.disabled" "old" "$(cat "$leave_dir/docker-compose.yml.disabled")"
assert_ok "leave keeps the data" test -d "$leave_dir/data"
assert_fails "task_in_container is false after leave" task_in_container leave
: >"$TMP/docker.log"
assert_ok "leave again (only .disabled left) is a no-op" container_leave leave
assert_eq "leave again calls no docker" "" "$(cat "$TMP/docker.log")"
echo new >"$leave_dir/docker-compose.yml"
MOCK_PS=abc123 container_leave leave >/dev/null 2>&1
assert_eq "leave after a re-enable replaces the old .disabled" "new" "$(cat "$leave_dir/docker-compose.yml.disabled")"
echo kept >"$leave_dir/docker-compose.yml"
printf 'no-such-unit-rpi-setup\n' >"$leave_dir/.native-units"
assert_ok "leave goes on when down fails" eval 'MOCK_PS=abc123 MOCK_DOWN_RC=1 container_leave leave >/dev/null 2>&1'
assert_eq "leave keeps the compose file when down fails" "kept" "$(cat "$leave_dir/docker-compose.yml")"
assert_fails "leave starts the native units again when down fails" test -e "$leave_dir/.native-units"
# Daemon down: "ps" fails, so nothing is known about the container; the run
# ends and the next run (with Docker started) takes it down.
printf 'no-such-unit-rpi-setup\n' >"$leave_dir/.native-units"
: >"$TMP/docker.log"
out="$( (MOCK_PS_RC=1 container_leave leave) 2>&1)" && rc=0 || rc=$?
assert_eq "leave fails when the Docker daemon is down" 1 "$rc"
assert_contains "leave says to start Docker" "Docker is not running" "$out"
assert_eq "leave keeps the compose file when the daemon is down" "kept" "$(cat "$leave_dir/docker-compose.yml")"
assert_ok "leave keeps the native units recorded when the daemon is down" test -e "$leave_dir/.native-units"
assert_lacks "leave runs no down when the daemon is down" " down" "$(cat "$TMP/docker.log")"
# No docker command at all: the native units come back, the file stays.
out="$( (have() { [[ "$1" != docker ]] && command -v "$1" >/dev/null 2>&1; }; container_leave leave) 2>&1)" && rc=0 || rc=$?
assert_eq "leave goes on without the docker command" 0 "$rc"
assert_contains "leave says Docker is missing" "Docker is not installed" "$out"
assert_eq "leave keeps the compose file without the docker command" "kept" "$(cat "$leave_dir/docker-compose.yml")"
assert_fails "leave starts the native units again without the docker command" test -e "$leave_dir/.native-units"
# Daemon up, no container: the project is gone, so the file is disabled.
MOCK_PS='' container_leave leave >/dev/null 2>&1
assert_fails "leave disables the compose file when Docker confirms there is no container" test -e "$leave_dir/docker-compose.yml"
unset -f docker
rm -rf "$leave_dir" "$TMP/docker.log"

# --- Docker: start, wait, roll back, leave ---------------------------------------
# compose_project <task> <command...>: a compose project running alpine.
compose_project() {
    local task="$1" dir
    shift
    dir="$(container_dir "$task")"
    install -d "$dir"
    {
        echo 'services:'
        echo "  $task:"
        echo '    image: alpine:3'
        echo "    container_name: rpi-setup-test-$task"
        echo '    restart: unless-stopped'
        printf '    command: ["sh", "-c", "%s"]\n' "$*"
    } >"$dir/docker-compose.yml"
    printf '%s\n' "$dir"
}

if docker info >/dev/null 2>&1; then
    up="$(compose_project up 'sleep 600')"
    assert_ok "container_pull pulls the project's image" container_pull "$up"
    assert_ok "container_up starts a container that stays up" container_up "$up" rpi-setup-test-up
    assert_contains "the container is running" "running" "$(container_state rpi-setup-test-up)"
    assert_ok "container_up again is a no-op for a running container" container_up "$up" rpi-setup-test-up

    crash="$(compose_project crash 'exit 3')"
    printf 'no-such-unit-rpi-setup\n' >"$crash/.native-units"
    out="$( (container_up "$crash" rpi-setup-test-crash) 2>&1)" && rc=0 || rc=$?
    assert_eq "container_up fails for a container that keeps restarting" "1" "$rc"
    assert_contains "the failure says the container does not stay up" "does not stay up" "$out"
    assert_eq "the failed container is taken down" "" "$(container_state rpi-setup-test-crash)"
    assert_eq "the failure rolls back to the native units" "no" "$([[ -e "$crash/.native-units" ]] && echo yes || echo no)"

    health="$(compose_project health 'touch /tmp/ok; sleep 600')"
    cat >>"$health/docker-compose.yml" <<'EOF'
    healthcheck:
      test: ["CMD", "test", "-f", "/tmp/ok"]
      interval: 2s
      start_period: 1s
EOF
    assert_ok "container_up waits for a passing health check" container_up "$health" rpi-setup-test-health
    assert_contains "the health check passed" "healthy" "$(container_state rpi-setup-test-health)"

    sick="$(compose_project sick 'sleep 600')"
    cat >>"$sick/docker-compose.yml" <<'EOF'
    healthcheck:
      test: ["CMD", "false"]
      interval: 1s
      retries: 1
EOF
    printf 'no-such-unit-rpi-setup\n' >"$sick/.native-units"
    out="$( (container_up "$sick" rpi-setup-test-sick) 2>&1)" && rc=0 || rc=$?
    assert_eq "container_up fails for a container whose health check fails" "1" "$rc"
    assert_contains "the failure says the health check fails" "health check fails" "$out"
    assert_eq "the unhealthy container is taken down" "" "$(container_state rpi-setup-test-sick)"
    assert_eq "the unhealthy container rolls back to the native units" "no" "$([[ -e "$sick/.native-units" ]] && echo yes || echo no)"

    container_leave up >/dev/null 2>&1
    assert_eq "container_leave takes the container down" "" "$(container_state rpi-setup-test-up)"
    assert_ok "container_leave disables the compose file" test -f "$up/docker-compose.yml.disabled"
    assert_fails "container_leave leaves no live compose file" test -e "$up/docker-compose.yml"
    assert_ok "container_leave without a container is a no-op" container_leave up
    assert_ok "container_leave without a project is a no-op" container_leave never-set-up
else
    skip "Docker cases need a running Docker daemon"
fi

finish_tests
