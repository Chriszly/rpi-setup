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
svc="$(teamspeak_usage_service "$TMP/ts" 030 secretpw 09988 kims-den.example 443)"
svc_default="$(teamspeak_usage_service "$TMP/ts" 30 secretpw)"
unset -f assign_uid chown
assert_contains "usage: builds the logger with its UID" 'UID: "12345"' "$svc"
assert_contains "usage: days as a plain number" 'USAGE_DAYS: "30"' "$svc"
assert_contains "usage: gets the serveradmin password" 'TS_QUERY_PASSWORD: "secretpw"' "$svc"
assert_contains "usage: gets the voice port on the Pi" 'TS_VOICE_PORT: "9988"' "$svc"
assert_contains "usage: gets the internet address" 'TS_PUBLIC_ADDRESS: "kims-den.example"' "$svc"
assert_contains "usage: gets the forwarded port" 'TS_PUBLIC_PORT: "443"' "$svc"
assert_contains "usage: no address looks up the public IP" 'TS_PUBLIC_ADDRESS: ""' "$svc_default"
assert_contains "usage: forwarded port defaults to the voice port" 'TS_PUBLIC_PORT: "9987"' "$svc_default"
assert_contains "usage: keeps its log next to the server" "source: $TMP/ts/usage/data" "$svc"
assert_ok "usage: copies the Dockerfile" cmp "$ROOT/templates/teamspeak-usage/Dockerfile" "$TMP/ts/usage/Dockerfile"
assert_ok "usage: copies the logger, runnable" test -x "$TMP/ts/usage/tsusage.py"

# --- internet address setting -------------------------------------------------
assert_eq "public address: empty looks it up" "" "$(teamspeak_public_address '')"
assert_eq "public address: a DynDNS name" "kims-den.dyndns.example" "$(teamspeak_public_address kims-den.dyndns.example)"
assert_eq "public address: an IPv4 address" "203.0.113.7" "$(teamspeak_public_address 203.0.113.7)"
assert_eq "public address: an IPv6 address" "2001:db8::7" "$(teamspeak_public_address 2001:db8::7)"
assert_eq "public address: Off turns it off" "no" "$(teamspeak_public_address Off)"
assert_fails "public address: a URL is refused" teamspeak_public_address 'http://kims-den.example'
assert_fails "public address: quotes are refused" teamspeak_public_address 'a"b'
assert_fails "public address: a blank is refused" teamspeak_public_address 'a b'

# --- usage logger: tsusage.py against a fake SSH query ------------------------------
if command -v python3 >/dev/null 2>&1; then
  bot="$ROOT/templates/teamspeak-usage/tsusage.py"
  data="$TMP/usage"
  mkdir -p "$data"
  export TS_PUBLIC_ADDRESS=no  # no lookups on the internet; the first run uses a file instead
  assert_eq "bot: answers ssh's password prompt" "pw 1" \
    "$(TSUSAGE_ASKPASS=1 TS_QUERY_PASSWORD='pw 1' python3 "$bot" 'Password:')"

  # First connect: Anna (and the query client itself) online; Bob joins and
  # Anna leaves; a minute later Bob is in a new server group, then the
  # connection drops.
  cat >"$TMP/fake1" <<'EOF'
#!/usr/bin/env bash
printf 'TS3\r\nWelcome to the TeamSpeak ServerQuery interface.\r\n'
while IFS= read -r cmd; do
  case "$cmd" in
    servergrouplist)
      printf 'sgid=1 name=Query\\sGuest type=2|sgid=6 name=Server\\sAdmin type=1|sgid=8 name=Guest type=1|'
      printf 'sgid=9 name=Member type=1\r\nerror id=0 msg=ok\r\n' ;;
    serverinfo)
      printf 'virtualserver_name=Our\\sServer virtualserver_maxclients=32 virtualserver_clientsonline=2 '
      printf 'virtualserver_uptime=3600 virtualserver_total_ping=12.5000 virtualserver_platform=Linux\r\nerror id=0 msg=ok\r\n' ;;
    channellist*)
      printf 'cid=2 pid=0 channel_order=1 channel_name=Games total_clients=1|cid=1 pid=0 channel_order=0 channel_name=Lobby total_clients=0|'
      printf 'cid=3 pid=2 channel_order=0 channel_name=Room\\s1 channel_topic=chill total_clients=0\r\nerror id=0 msg=ok\r\n' ;;
    *-away*)
      printf 'clid=1 cid=1 client_nickname=serveradmin client_type=1 client_servergroups=1|'
      printf 'clid=7 cid=2 client_nickname=Bob client_type=0 client_servergroups=6,9 client_away=1 client_away_message=brb '
      printf 'client_input_muted=1 client_output_muted=0 client_input_hardware=1 client_output_hardware=1 client_idle_time=65000 '
      printf 'client_version=6.0.0\\s[Build:\\s1] client_platform=Windows client_country=DE client_created=1000\r\nerror id=0 msg=ok\r\n' ;;
    clientlist*)
      printf 'clid=1 client_nickname=serveradmin client_type=1 client_unique_identifier=serveradmin client_servergroups=1|'
      printf 'clid=5 client_nickname=Anna\\sB\\p1 client_type=0 client_unique_identifier=AAA= client_servergroups=8 connection_client_ip=10.0.0.5\r\nerror id=0 msg=ok\r\n'
      printf 'notifycliententerview cfid=0 ctid=1 reasonid=0 clid=7 client_unique_identifier=BBB= client_nickname=Bob client_type=0 client_servergroups=9 connection_client_ip=10.0.0.5\r\n'
      printf 'notifycliententerview cfid=0 ctid=1 reasonid=0 clid=8 client_unique_identifier=q client_nickname=bot client_type=1\r\n'
      printf 'notifyclientleftview cfid=1 ctid=0 reasonid=8 reasonmsg=leaving clid=5\r\n' ;;
    version) printf 'version=6 build=1 platform=Linux\r\nerror id=0 msg=ok\r\n'; sleep 0.3; exit 0 ;;
    *) printf 'error id=0 msg=ok\r\n' ;;
  esac
done
EOF
  printf '203.0.113.7\n' >"$TMP/myip"
  USAGE_DATA="$data" TS_SSH_CMD="bash $TMP/fake1" TS_VOICE_PORT=9988 TS_PUBLIC_ADDRESS='' \
    TS_PUBLIC_IP_URLS="file://$TMP/no-such-file file://$TMP/myip" timeout 2 python3 -B "$bot" 2>/dev/null || true
  assert_eq "bot: looks up the public IP (the first service that answers), with the voice port" \
    "203.0.113.7 203.0.113.7 9988 9988 True" "$(python3 -c '
import json, sys
u = json.load(open(sys.argv[1] + "/usage.json"))
p = u["public"]
print(p["address"], p["ip"], p["port"], u["voice_port"], p["checked"].endswith("Z"))
' "$data" 2>&1)"
  first="$(python3 -c '
import json, sys
d = sys.argv[1]
for l in open(d + "/sessions.jsonl"): s = json.loads(l); print("visit", s["nick"], s["uid"], s["groups"], s["ip"])
o = json.load(open(d + "/online.json"))
for k, c in sorted(o["clients"].items()): print("online", k, c["nick"])
u = json.load(open(d + "/usage.json"))
print("page", [c["nick"] for c in u["online"]], [v["nick"] for v in u["recent"]], [(x["nick"], x["online"]) for x in u["users"]])
print("groups", [(x["nick"], x["groups"]) for x in u["users"]], [v["groups"] for v in u["recent"]])
print("server", u["server"]["name"], u["server"]["max_clients"], u["server"]["ping"])
print("channels", [(c["name"], c["depth"], c["clients"]) for c in u["channels"]])
c = u["clients"][0]
print("client", c["nick"], c["channel"], c["platform"], c["version"], c["country"], c["away"], c["away_message"], c["input_muted"], c["idle_seconds"])
print("busy", [b["name"] for b in u["busy_channels"]], len(u["heatmap"]))
print("people", [(p["nick"], p["visits"], p["platform"], p["first_seen"][:4]) for p in u["people"]])
print("connections", [(g["nick"], g["others"], g["identities"], g["visits"], g["online"]) for g in u["connections"]])
print("ip shown", "10.0.0" in open(d + "/usage.json").read())
' "$data" 2>&1)" || true
  assert_eq "bot: logs joins and leaves and server groups, skips query clients, unescapes nicknames" \
"visit Anna B|1 AAA= ['Guest'] 10.0.0.5
online 7 Bob
page ['Bob'] ['Anna B|1'] [('Bob', True), ('Anna B|1', False)]
groups [('Bob', ['Server Admin', 'Member']), ('Anna B|1', ['Guest'])] [['Guest']]
server Our Server 32 12.5
channels [('Lobby', 0, []), ('Games', 0, ['Bob']), ('Room 1', 1, [])]
client Bob Games Windows 6.0.0 DE True brb True 65
busy [] 168
people [('Bob', 1, 'Windows', '1970'), ('Anna B|1', 1, '', '$(date -u +%Y)')]
connections [('Bob', ['Anna B|1'], 2, 2, True)]
ip shown False" "$first"

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
  USAGE_DATA="$data" TS_SSH_CMD="bash $TMP/fake2" timeout 2 python3 -B "$bot" 2>/dev/null || true
  assert_eq "bot: a visit that ended while it was away is closed on reconnect" \
    $'Anna B|1\nBob' "$(python3 -c 'import json,sys; [print(json.loads(l)["nick"]) for l in open(sys.argv[1])]' "$data/sessions.jsonl" 2>&1)"
  assert_contains "bot: who is online now" '"online":[{"nick":"Carl"' "$(USAGE_DATA="$data" python3 "$bot" --summary)"

  # How many were online at once: A from before the 7 days until +50, B from
  # +10 to +60, C from +60 (B's end, no change) to +70, D online since +65.
  assert_eq "bot: online at the same time, as the points where the count changes" \
    "[[0, 1], [10, 2], [50, 1], [65, 2], [70, 1], [604800, 1]]" "$(python3 -I -B -c '
import sys; sys.path.insert(0, sys.argv[1]); import tsusage as t
w = 7 * 86400
s = [{"uid": "a", "nick": "A", "start": -100, "end": 50}, {"uid": "b", "nick": "B", "start": 10, "end": 60},
     {"uid": "c", "nick": "C", "start": 60, "end": 70}, {"uid": "e", "nick": "E", "start": -900, "end": -5}]
print(t.concurrent({"1": {"uid": "d", "nick": "D", "since": 65}}, s, w + 0.5))
' "$ROOT/templates/teamspeak-usage" 2>&1)"

  # The internet address: a lookup every 30 minutes, 5 after a failure that
  # keeps the last address; a DynDNS name with what it resolves to; or none.
  assert_eq "bot: internet address from a lookup, a name or none" \
"lookup 198.51.100.4 198.51.100.4 9987
not again within 30 min True
kept after a failure, retried in 5 min 198.51.100.4 True
name localhost 127.0.0.1 443
unknown name no-such-host.invalid  443
off {}" "$(python3 -I -B -c '
import sys; sys.path.insert(0, sys.argv[1]); import tsusage as t
answers = ["198.51.100.4", ""]
t.public_ip = lambda urls: answers.pop(0)
t.log = lambda msg: None
t.PUBLIC_ADDRESS, t.PUBLIC_PORT = "", "9987"
u = t.Usage.__new__(t.Usage); u.public = {}; u.public_next = 0
u.set_public(1000); p = u.public; print("lookup", p["address"], p["ip"], p["port"])
u.set_public(1000 + t.PUBLIC_EVERY - 1); print("not again within 30 min", len(answers) == 1)
u.set_public(1000 + t.PUBLIC_EVERY)
print("kept after a failure, retried in 5 min", u.public["ip"], u.public_next == 1000 + t.PUBLIC_EVERY + t.PUBLIC_RETRY)
t.PUBLIC_ADDRESS, t.PUBLIC_PORT = "localhost", "443"
u.public_next = 0; u.set_public(5000); p = u.public; print("name", p["address"], p["ip"], p["port"])
t.PUBLIC_ADDRESS = "no-such-host.invalid"
u.public_next = 0; u.set_public(6000); p = u.public; print("unknown name", p["address"], p["ip"], p["port"])
t.PUBLIC_ADDRESS = "No"
u.public = {}; u.public_next = 0; u.set_public(7000); print("off", u.public)
' "$ROOT/templates/teamspeak-usage" 2>&1)"

  cat >"$TMP/fake3" <<'EOF'
#!/usr/bin/env bash
read -r _; printf 'error id=520 msg=invalid\\sloginname\\sor\\spassword\r\n'
EOF
  log="$(USAGE_DATA="$TMP/usage3" TS_SSH_CMD="bash $TMP/fake3" timeout 1 python3 -B "$bot" 2>&1)" || true
  assert_contains "bot: reports a query error and retries" "use: invalid loginname or password; trying again" "$log"
  assert_fails "bot: writes no usage.json for the page without a connection" test -e "$TMP/usage3/usage.json"
else
  skip "bot: python3 not installed"
fi

finish_tests
