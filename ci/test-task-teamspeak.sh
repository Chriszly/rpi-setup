#!/usr/bin/env bash
# test-task-teamspeak.sh - unit tests for tasks/teamspeak.sh: which voice port
# the server listens on inside the container (and is recorded in voice-port)
# for new and existing servers, and reading the privilege key from its log.
#
# Run: bash ci/test-task-teamspeak.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/teamspeak.sh"

# --- new server: takes the configured port and records it ---------------------
d="$TMP/new"; mkdir -p "$d"
assert_eq "new server uses the configured port" "9988" "$(teamspeak_server_port "$d" 1 9988)"
assert_eq "new server records the port" "9988" "$(cat "$d/voice-port")"

# --- existing server: keeps the recorded port whatever is configured -----------
assert_eq "existing server keeps the recorded port" "9988" "$(teamspeak_server_port "$d" 0 9999)"
assert_eq "existing server: record unchanged" "9988" "$(cat "$d/voice-port")"
printf ' 9990 \n' >"$d/voice-port"
assert_eq "recorded port with blanks" "9990" "$(teamspeak_server_port "$d" 0 9987)"

# --- existing server without a record: old compose file, else 9987 -------------
d="$TMP/old"; mkdir -p "$d"
printf '%s\n' 'services:' '    environment:' '      TSSERVER_DEFAULT_PORT: "9991"' >"$d/docker-compose.yml"
assert_eq "unrecorded server uses the port in its compose file" "9991" "$(teamspeak_server_port "$d" 0 9987)"
assert_eq "unrecorded server: port gets recorded" "9991" "$(cat "$d/voice-port")"

d="$TMP/older"; mkdir -p "$d"
assert_eq "unrecorded server without compose file uses 9987" "9987" "$(teamspeak_server_port "$d" 0 9988)"
assert_eq "unrecorded server: 9987 gets recorded" "9987" "$(cat "$d/voice-port")"

# --- a broken record stops the task -------------------------------------------
printf 'abc\n' >"$d/voice-port"
assert_fails "broken record dies" teamspeak_server_port "$d" 0 9987
printf '70000\n' >"$d/voice-port"
assert_fails "out-of-range record dies" teamspeak_server_port "$d" 0 9987

# --- privilege key: the token line below the banner, not the banner -----------
docker() {
  printf '%s\n' '------------------------------------------------------------------' \
    '      ServerAdmin privilege key created, please use it to gain' \
    '      serveradmin rights for your virtualserver. please' \
    '      also check the doc/privilegekey_guide.txt for details.' '' \
    '       token=AbC+d/12eF=' '------------------------------------------------------------------'
}
assert_eq "privilege key is read from the token line" "AbC+d/12eF=" "$(teamspeak_token teamspeak)"
docker() { echo 'TeamSpeak server starting'; }
assert_eq "no token in the log gives an empty key" "" "$(teamspeak_token teamspeak)"
assert_ok "no token in the log is not an error (set -e)" teamspeak_token teamspeak
unset -f docker

finish_tests
