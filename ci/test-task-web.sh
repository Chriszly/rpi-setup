#!/usr/bin/env bash
# test-task-web.sh - unit tests for tasks/web.sh: the start page and the
# service list script the timer runs (with docker, curl, systemctl and
# hostname replaced by stubs).
#
# Run: bash ci/test-task-web.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/web.sh"

# --- the start page --------------------------------------------------------------
WEB_TITLE='My "Pi" \1 home'
web_index_page "$TMP/index.html" >/dev/null
page="$(cat "$TMP/index.html")"
assert_contains "page: title" '<title>My "Pi" \1 home</title>' "$page"
assert_lacks "page: no placeholder left" "@TITLE@" "$page"
assert_contains "page: follows the browser's dark setting" "@media (prefers-color-scheme: dark)" "$page"
assert_contains "page: reads the service list" "get('services.json'" "$page"
assert_contains "page: reads the container list" "get('containers.json'" "$page"
assert_contains "page: marked as rpi-setup's own" "rpi-setup" "$page"
WEB_TITLE=Other
web_index_page "$TMP/index.html" >/dev/null
assert_contains "page: a new WEB_TITLE replaces rpi-setup's page" "<title>Other</title>" "$(cat "$TMP/index.html")"
echo 'my own page' >"$TMP/index.html"
web_index_page "$TMP/index.html" >/dev/null
assert_eq "page: a page of your own is kept" "my own page" "$(cat "$TMP/index.html")"

# --- the service list script -----------------------------------------------------
web_links_script "$TMP/html/services.json" >"$TMP/web-links"
assert_ok "script: valid bash" bash -n "$TMP/web-links"
assert_contains "script: writes to the given file" "WL_OUT=$TMP/html/services.json" "$(cat "$TMP/web-links")"

bin="$TMP/bin" opt="$TMP/opt"
install -d "$bin" "$TMP/html" "$opt/pihole" "$opt/netalertx"
touch "$opt/pihole/docker-compose.yml"
printf 'services:\n  netalertx:\n    environment:\n      PORT: 20211\n' >"$opt/netalertx/docker-compose.yml"

cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps) printf '%s\n' web usage-control netalertx teamspeak myapp labelled hidden localonly evil ;;
  exec) printf '80o,443os,[::]:80o\n' ;;
  inspect)
    if [[ "$2" == --type ]]; then [[ "$4" == pihole ]]; exit; fi
    if [[ "$3" == '{{.Name}}'* ]]; then
      printf '/web\x1fnginx:stable-alpine\x1frunning\x1f\x1f2026-10-03T09:55:01.123456789Z\x1f0001-01-01T00:00:00Z\x1f0\x1fhost\x1f\n'
      printf '/old\x1fbusybox\x1fexited\x1f\x1f2026-10-01T08:00:00.5Z\x1f2026-10-02T08:00:00.5Z\x1f3\x1fbridge\x1f\n'
      printf '/usage-control\x1fghcr.io/chriszly/usage-control:main\x1frunning\x1fhealthy\x1f2026-10-03T10:00:00.1Z\x1f0001-01-01T00:00:00Z\x1f0\x1fbridge\x1f'
      printf '0.0.0.0:8090>9393/tcp :::8090>9393/tcp 127.0.0.1:9999>80/tcp \n'
      exit
    fi
    case "${*: -1}" in
      labelled) printf '\x1f9000\x1fMy App\x1f/ui/\x1fDoes things\n' ;;
      hidden) printf 'no\x1f9001\x1f\x1f\x1f\n' ;;
      evil) printf '\x1f9100\x1fa"b\\c\x1fjavascript:alert(1)\x1f\n' ;;
      *) printf '<no value>\x1f<no value>\x1f<no value>\x1f<no value>\x1f<no value>\n' ;;
    esac ;;
  port)
    case "$2" in
      usage-control) printf '8080/tcp -> 0.0.0.0:8081\n8080/tcp -> [::]:8081\n' ;;
      myapp) printf '5000/tcp -> 0.0.0.0:5000\n6000/tcp -> 0.0.0.0:6000\n' ;;
      localonly) printf '80/tcp -> 127.0.0.1:9999\n' ;;
      teamspeak) printf '30033/tcp -> 0.0.0.0:30033\n' ;;
    esac ;;
esac
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
echo "$url" >>"${0%/*}/curl.log"
case "$url" in
  *:5000/*) printf '000'; exit 7 ;;
  *:8081/*) printf '000'; exit 7 ;;
  *) printf '200' ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 3\n' >"$bin/systemctl"
printf '#!/usr/bin/env bash\necho rasPi\n' >"$bin/hostname"
chmod +x "$bin"/*

run_links() { PATH="$bin:$PATH" RPI_SETUP_CONTAINER_ROOT="$opt" bash "$TMP/web-links"; }
assert_ok "script: runs" run_links
json="$(cat "$TMP/html/services.json" 2>/dev/null || true)"

if command -v python3 >/dev/null 2>&1; then
  summary="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["host"])
for s in d["services"]:
    print("%s|%s|%s|%s|%s" % (s["name"], s["description"], s["port"], s["path"], s["up"]))
' "$TMP/html/services.json" 2>&1)" || summary="not JSON: $summary"
  expected='rasPi
Pi-hole|Blocks ads and trackers for every device on the network|80|/admin/|True
a"b\c||9100|/|True
My App|Does things|9000|/ui/|True
myapp||6000|/|True
NetAlertX|Which devices are on the network, and when|20211|/|True
usage-control|CPU, memory and temperature of this Pi|8081|/|False'
  assert_eq "list: Pi-hole first, then the running containers by name" "$expected" "$summary"
else
  skip "list: python3 not installed"
fi
assert_lacks "list: a hidden container is left out" '9001' "$json"
assert_lacks "list: a port bound to localhost only is left out" '9999' "$json"
assert_lacks "list: TeamSpeak is not a web page" '30033' "$json"
assert_lacks "list: a port that does not answer HTTP is left out" '5000' "$json"
assert_lacks "list: nginx itself is not listed" '"web"' "$json"
assert_lacks "list: a label cannot set a javascript: link" 'javascript' "$json"

containers="$(cat "$TMP/html/containers.json" 2>/dev/null || true)"
assert_eq "containers: every container by name, ports once each, times in seconds" \
'{"containers":[
{"name":"old","image":"busybox","state":"exited","health":"","started":"2026-10-01T08:00:00Z","finished":"2026-10-02T08:00:00Z","restarts":3,"network":"bridge","ports":[]},
{"name":"usage-control","image":"ghcr.io/chriszly/usage-control:main","state":"running","health":"healthy","started":"2026-10-03T10:00:00Z","finished":"","restarts":0,"network":"bridge","ports":["8090:9393/tcp"]},
{"name":"web","image":"nginx:stable-alpine","state":"running","health":"","started":"2026-10-03T09:55:01Z","finished":"","restarts":0,"network":"host","ports":[]}
]}' "$containers"
if command -v python3 >/dev/null 2>&1; then
  assert_ok "containers: valid JSON" python3 -m json.tool "$TMP/html/containers.json"
fi

inode="$(stat -c %i "$TMP/html/services.json")"
cinode="$(stat -c %i "$TMP/html/containers.json")"
run_links
assert_eq "script: an unchanged list is not written again" "$inode" "$(stat -c %i "$TMP/html/services.json")"
assert_eq "script: unchanged containers are not written again" "$cinode" "$(stat -c %i "$TMP/html/containers.json")"

printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/docker"
rm -f "$opt/pihole/docker-compose.yml"
assert_ok "script: runs without Docker" run_links
assert_eq "list: empty without Docker or Pi-hole" $'{"host":"rasPi","services":[\n\n]}' "$(cat "$TMP/html/services.json")"
assert_eq "containers: empty without Docker" $'{"containers":[\n\n]}' "$(cat "$TMP/html/containers.json")"

finish_tests
