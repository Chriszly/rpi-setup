#!/usr/bin/env bash
# test-task-teamspeak.sh - unit tests for tasks/teamspeak.sh: which voice port
# the server listens on inside the container (and is recorded in voice-port)
# for new and existing servers, reading the privilege key from its log, the
# usage logger's compose service, and the logger itself (tsusage.py, against a
# fake SSH query; needs python3).
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

# --- usage logger: compose service and its files --------------------------------
assign_uid() { echo 12345; }
chown() { :; }
RPI_SETUP_ROOT="$ROOT"
svc="$(teamspeak_usage_service "$TMP/ts" 030 secretpw)"
unset -f assign_uid chown
assert_contains "usage: builds the logger with its UID" 'UID: "12345"' "$svc"
assert_contains "usage: days as a plain number" 'USAGE_DAYS: "30"' "$svc"
assert_contains "usage: gets the serveradmin password" 'TS_QUERY_PASSWORD: "secretpw"' "$svc"
assert_contains "usage: keeps its log next to the server" "source: $TMP/ts/usage/data" "$svc"
assert_ok "usage: copies the Dockerfile" cmp "$ROOT/templates/teamspeak-usage/Dockerfile" "$TMP/ts/usage/Dockerfile"
assert_ok "usage: copies the logger, runnable" test -x "$TMP/ts/usage/tsusage.py"

# --- usage logger: tsusage.py against a fake SSH query ------------------------------
if command -v python3 >/dev/null 2>&1; then
  bot="$ROOT/templates/teamspeak-usage/tsusage.py"
  data="$TMP/usage"
  mkdir -p "$data"
  assert_eq "bot: answers ssh's password prompt" "pw 1" \
    "$(TSUSAGE_ASKPASS=1 TS_QUERY_PASSWORD='pw 1' python3 "$bot" 'Password:')"

  # First connect: Anna (and the query client itself) online; Bob joins and
  # Anna leaves, then the connection drops.
  cat >"$TMP/fake1" <<'EOF'
#!/usr/bin/env bash
printf 'TS3\r\nWelcome to the TeamSpeak ServerQuery interface.\r\n'
while IFS= read -r cmd; do
  case "$cmd" in
    clientlist*)
      printf 'clid=1 client_nickname=serveradmin client_type=1 client_unique_identifier=serveradmin|'
      printf 'clid=5 client_nickname=Anna\\sB\\p1 client_type=0 client_unique_identifier=AAA=\r\nerror id=0 msg=ok\r\n'
      printf 'notifycliententerview cfid=0 ctid=1 reasonid=0 clid=7 client_unique_identifier=BBB= client_nickname=Bob client_type=0\r\n'
      printf 'notifycliententerview cfid=0 ctid=1 reasonid=0 clid=8 client_unique_identifier=q client_nickname=bot client_type=1\r\n'
      printf 'notifyclientleftview cfid=1 ctid=0 reasonid=8 reasonmsg=leaving clid=5\r\n' ;;
    version) printf 'version=6 build=1 platform=Linux\r\nerror id=0 msg=ok\r\n'; sleep 0.3; exit 0 ;;
    *) printf 'error id=0 msg=ok\r\n' ;;
  esac
done
EOF
  USAGE_DATA="$data" TS_SSH_CMD="bash $TMP/fake1" timeout 2 python3 "$bot" 2>/dev/null || true
  first="$(python3 -c '
import json, sys
d = sys.argv[1]
for l in open(d + "/sessions.jsonl"): s = json.loads(l); print("visit", s["nick"], s["uid"])
o = json.load(open(d + "/online.json"))
for k, c in sorted(o["clients"].items()): print("online", k, c["nick"])
u = json.load(open(d + "/usage.json"))
print("page", [c["nick"] for c in u["online"]], [v["nick"] for v in u["recent"]], [(x["nick"], x["online"]) for x in u["users"]])
' "$data" 2>&1)" || true
  assert_eq "bot: logs joins and leaves, skips query clients, unescapes nicknames" \
"visit Anna B|1 AAA=
online 7 Bob
page ['Bob'] ['Anna B|1'] [('Bob', True), ('Anna B|1', False)]" "$first"

  # Second connect: Bob left while the bot was away, Carl is on.
  cat >"$TMP/fake2" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r cmd; do
  case "$cmd" in
    clientlist*) printf 'clid=3 client_nickname=Carl client_type=0 client_unique_identifier=CCC=\r\nerror id=0 msg=ok\r\n' ;;
    version) printf 'version=6\r\nerror id=0 msg=ok\r\n'; sleep 0.3; exit 0 ;;
    *) printf 'error id=0 msg=ok\r\n' ;;
  esac
done
EOF
  USAGE_DATA="$data" TS_SSH_CMD="bash $TMP/fake2" timeout 2 python3 "$bot" 2>/dev/null || true
  assert_eq "bot: a visit that ended while it was away is closed on reconnect" \
    $'Anna B|1\nBob' "$(python3 -c 'import json,sys; [print(json.loads(l)["nick"]) for l in open(sys.argv[1])]' "$data/sessions.jsonl" 2>&1)"
  assert_contains "bot: who is online now" '"online":[{"nick":"Carl"' "$(USAGE_DATA="$data" python3 "$bot" --summary)"

  cat >"$TMP/fake3" <<'EOF'
#!/usr/bin/env bash
read -r _; printf 'error id=520 msg=invalid\\sloginname\\sor\\spassword\r\n'
EOF
  log="$(USAGE_DATA="$TMP/usage3" TS_SSH_CMD="bash $TMP/fake3" timeout 1 python3 "$bot" 2>&1)" || true
  assert_contains "bot: reports a query error and retries" "use: invalid loginname or password; trying again" "$log"
else
  skip "bot: python3 not installed"
fi

finish_tests
