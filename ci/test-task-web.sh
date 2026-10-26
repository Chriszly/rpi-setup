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

# web_port: the start page gets port 80, moving Pi-hole's admin UI off it.
web_port_with() {  # owner of port 80, WEB_PORT, PIHOLE_WEB_PORT, port used so far
  ( OWNER80="$1" WEB_PORT="$2" PIHOLE_WEB_PORT="$3"
    port_owner() { [[ "$1" == 80 && -n "$OWNER80" ]] && echo "$OWNER80"; }
    web_move_pihole() { echo "$1" >"$TMP/moved"; }
    web_port "${4:-}" 2>/dev/null )
}
assert_eq "web_port takes a free port 80" "80" "$(web_port_with '' '' '')"
assert_eq "web_port keeps port 80 from nginx" "80" "$(web_port_with nginx '' '')"
assert_eq "web_port moves Pi-hole off port 80" "80" "$(web_port_with pihole-FTL '' '')"
assert_eq "web_port moves Pi-hole to 8080 by default" "8080" "$(cat "$TMP/moved")"
web_port_with pihole-FTL '' 8085 >/dev/null
assert_eq "web_port moves Pi-hole to PIHOLE_WEB_PORT" "8085" "$(cat "$TMP/moved")"
assert_eq "web_port uses 8080 when Pi-hole must keep 80" "8080" "$(web_port_with pihole-FTL '' 80)"
assert_eq "web_port uses 8080 when another server has 80" "8080" "$(web_port_with apache2 '' '')"
assert_eq "web_port follows WEB_PORT" "8081" "$(web_port_with pihole-FTL 8081 '')"
assert_fails "web_port dies when WEB_PORT and PIHOLE_WEB_PORT both want 80" web_port_with pihole-FTL 80 80
assert_eq "web_port keeps the port used so far" "8090" "$(web_port_with pihole-FTL '' '' 8090)"
assert_eq "web_port leaves the old 8080 fallback for port 80" "80" "$(web_port_with pihole-FTL '' '' 8080)"
assert_eq "web_port follows WEB_PORT over the port used so far" "8091" "$(web_port_with '' 8091 '' 8090)"

# web_move_pihole: the Pi-hole container's admin port moves to PIHOLE_WEB_PORT.
mkdir -p "$TMP/opt/pihole"
printf 'services:\n  pihole:\n    environment:\n      FTLCONF_webserver_port: "80o,[::]:80o"\n' >"$TMP/opt/pihole/docker-compose.yml"
out="$( RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
  task_in_container() { true; }; port_owner() { return 1; }
  # shellcheck disable=SC2032  # a stub; web.sh's xargs calls run the real docker
  docker() { :; }
  web_move_pihole 8085 2>&1 )"
assert_contains "move Pi-hole: says where the admin went" ":8085/admin" "$out"
assert_contains "move Pi-hole: rewrites the compose port" 'FTLCONF_webserver_port: "8085o,[::]:8085o"' \
    "$(cat "$TMP/opt/pihole/docker-compose.yml")"
# nginx on 8080 (the old fallback) is stopped so Pi-hole can take that port.
out="$( RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
  task_in_container() { [[ "$1" == pihole ]]; }; port_owner() { [[ "$1" == 8080 ]] && echo nginx; }
  systemctl() { echo "systemctl $*"; }
  # shellcheck disable=SC2032  # a stub; web.sh's xargs calls run the real docker
  docker() { :; }
  web_move_pihole 8080 2>&1 )"
assert_contains "move Pi-hole: stops nginx on the target port" "systemctl stop nginx" "$out"
assert_contains "move Pi-hole: then moves it there" ":8080/admin" "$out"

# --- the start page --------------------------------------------------------------
WEB_TITLE='My "Pi" \1 home'
web_index_page "$TMP/index.html" >/dev/null
page="$(cat "$TMP/index.html")"
assert_contains "page: title" '<title>My "Pi" \1 home</title>' "$page"
assert_lacks "page: no placeholder left" "@TITLE@" "$page"
assert_contains "page: follows the browser's dark setting" "@media (prefers-color-scheme: dark)" "$page"
assert_contains "page: reads the service list" "get('services.json'" "$page"
assert_contains "page: reads the container list" "get('containers.json'" "$page"
assert_contains "page: reads the TeamSpeak usage" "get('teamspeak.json'" "$page"
assert_contains "page: reads the tasks set up here" "get('tasks.json'" "$page"
assert_contains "page: reads the update check" "get('updates.json'" "$page"
assert_contains "page: links the rpi-setup repository" 'href="https://github.com/Programmer-Den/rpi-setup"' "$page"
assert_contains "page: charts how many were online at once" "chartTab.render(data.concurrent)" "$page"
assert_contains "page: shows each user's server groups" "groups: u.groups" "$page"
assert_contains "page: has a Docker tab" 'href="#docker"' "$page"
assert_contains "page: has a TeamSpeak tab" 'href="#teamspeak"' "$page"
overview="${page#*<div id=\"page-overview\">}"
overview="${overview%%<div id=\"page-docker\"*}"
assert_lacks "page: the overview has no TeamSpeak data" 'TeamSpeak' "$overview"
assert_lacks "page: the overview has no container list" 'containers' "$overview"
assert_contains "page: groups visitors from the same connection" "data.connections" "$page"
assert_contains "page: TeamSpeak tab shows the server, channels and busy times" "renderServer(data.server" "$page"
assert_contains "page: TeamSpeak tab shows the internet address" "'Internet address'" "$page"
assert_contains "page: ... with the voice port on the Pi for the LAN address" "data.voice_port" "$page"
assert_contains "page: marked as rpi-setup's own" "rpi-setup" "$page"
WEB_TITLE=Other
web_index_page "$TMP/index.html" >/dev/null
assert_contains "page: a new WEB_TITLE replaces rpi-setup's page" "<title>Other</title>" "$(cat "$TMP/index.html")"
echo 'my own page' >"$TMP/index.html"
web_index_page "$TMP/index.html" >/dev/null
assert_eq "page: a page of your own is kept" "my own page" "$(cat "$TMP/index.html")"

# --- the service list script -----------------------------------------------------
TASKS=("base|OS update, EEPROM firmware" "web|nginx with a start page" "docker|Docker Engine")
RPI_SETUP_DONE_FILE="$TMP/tasks.done"
printf '%s\n' docker base 'bad name' gone >"$RPI_SETUP_DONE_FILE"
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
  ps) printf '%s\n' web den-watcher netalertx teamspeak myapp labelled hidden localonly evil ;;
  exec) printf '80o,443os,[::]:80o\n' ;;
  inspect)
    if [[ "$2" == --type ]]; then [[ "$4" == pihole ]]; exit; fi
    if [[ "$3" == '{{.Name}}'* ]]; then
      printf '/web\x1fnginx:stable-alpine\x1frunning\x1f\x1f2026-10-03T09:55:01.123456789Z\x1f0001-01-01T00:00:00Z\x1f0\x1fhost\x1f\n'
      printf '/old\x1fbusybox\x1fexited\x1f\x1f2026-10-01T08:00:00.5Z\x1f2026-10-02T08:00:00.5Z\x1f3\x1fbridge\x1f\n'
      printf '/den-watcher\x1fghcr.io/programmer-den/den-watcher:main\x1frunning\x1fhealthy\x1f2026-10-03T10:00:00.1Z\x1f0001-01-01T00:00:00Z\x1f0\x1fbridge\x1f'
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
      den-watcher) printf '8080/tcp -> 0.0.0.0:8081\n8080/tcp -> [::]:8081\n' ;;
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
cat >"$bin/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -I ]]; then echo "192.168.60.10 172.17.0.1"; else echo rasPi; fi
EOF
printf '#!/usr/bin/env bash\necho "1.1.1.1 via 192.168.60.1 dev eth0 src 192.168.60.9 uid 0"\n' >"$bin/ip"
chmod +x "$bin"/*

run_links() { PATH="$bin:$PATH" RPI_SETUP_CONTAINER_ROOT="$opt" bash "$TMP/web-links"; }
assert_ok "script: runs" run_links
json="$(cat "$TMP/html/services.json" 2>/dev/null || true)"

if command -v python3 >/dev/null 2>&1; then
  summary="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["host"], d["ip"])
for s in d["services"]:
    print("%s|%s|%s|%s|%s" % (s["name"], s["description"], s["port"], s["path"], s["up"]))
' "$TMP/html/services.json" 2>&1)" || summary="not JSON: $summary"
  expected='rasPi 192.168.60.9
Pi-hole|Blocks ads and trackers for every device on the network|80|/admin/|True
Den-Watcher|CPU, memory, temperature and disks of this Pi, with their history|8081|/|False
a"b\c||9100|/|True
My App|Does things|9000|/ui/|True
myapp||6000|/|True
NetAlertX|Which devices are on the network, and when|20211|/|True'
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
{"name":"den-watcher","image":"ghcr.io/programmer-den/den-watcher:main","state":"running","health":"healthy","started":"2026-10-03T10:00:00Z","finished":"","restarts":0,"network":"bridge","ports":["8090:9393/tcp"]},
{"name":"old","image":"busybox","state":"exited","health":"","started":"2026-10-01T08:00:00Z","finished":"2026-10-02T08:00:00Z","restarts":3,"network":"bridge","ports":[]},
{"name":"web","image":"nginx:stable-alpine","state":"running","health":"","started":"2026-10-03T09:55:01Z","finished":"","restarts":0,"network":"host","ports":[]}
]}' "$containers"
if command -v python3 >/dev/null 2>&1; then
  assert_ok "containers: valid JSON" python3 -m json.tool "$TMP/html/containers.json"
fi

assert_eq "tasks: the finished tasks by name with their description, and web" \
'{"tasks":[
{"name":"base","description":"OS update, EEPROM firmware"},
{"name":"docker","description":"Docker Engine"},
{"name":"gone","description":""},
{"name":"web","description":"nginx with a start page"}
]}' "$(cat "$TMP/html/tasks.json" 2>/dev/null)"

inode="$(stat -c %i "$TMP/html/services.json")"
cinode="$(stat -c %i "$TMP/html/containers.json")"
run_links
assert_eq "script: an unchanged list is not written again" "$inode" "$(stat -c %i "$TMP/html/services.json")"
assert_eq "script: unchanged containers are not written again" "$cinode" "$(stat -c %i "$TMP/html/containers.json")"

assert_eq "teamspeak: no teamspeak.json without the usage logger" no "$(test -e "$TMP/html/teamspeak.json" && echo yes || echo no)"
install -d "$opt/teamspeak/usage/data"
echo '{"online":[]}' >"$opt/teamspeak/usage/data/usage.json"
run_links
assert_eq "teamspeak: a fresh usage summary is copied" '{"online":[]}' "$(cat "$TMP/html/teamspeak.json" 2>/dev/null)"
touch -d '-11 minutes' "$opt/teamspeak/usage/data/usage.json"
run_links
assert_eq "teamspeak: a stale summary is removed" no "$(test -e "$TMP/html/teamspeak.json" && echo yes || echo no)"

printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/docker"
printf '#!/usr/bin/env bash\nexit 2\n' >"$bin/ip"
rm -f "$opt/pihole/docker-compose.yml"
assert_ok "script: runs without Docker" run_links
assert_eq "list: empty without Docker or Pi-hole; the address from hostname -I without a route" $'{"host":"rasPi","ip":"192.168.60.10","services":[\n\n]}' "$(cat "$TMP/html/services.json")"
assert_eq "containers: empty without Docker" $'{"containers":[\n\n]}' "$(cat "$TMP/html/containers.json")"

# --- the update check script -----------------------------------------------------
d1="sha256:$(printf '1%.0s' {1..64})" d2="sha256:$(printf '2%.0s' {1..64})" d3="sha256:$(printf '3%.0s' {1..64})"
RPI_SETUP_ROOT="$TMP/checkout"
web_updates_script "$TMP/html/updates.json" >"$TMP/updates"
assert_ok "updates: valid bash" bash -n "$TMP/updates"
assert_contains "updates: writes to the given file" "WU_OUT=$TMP/html/updates.json" "$(cat "$TMP/updates")"

ubin="$TMP/ubin"
install -d "$ubin"
# Containers: web and web2 run the newest nginx, den-watcher an old image,
# built is built on the Pi, pinned is pinned by digest, private cannot be
# asked.
cat >"$ubin/docker" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  'info '*) exit 0 ;;
  'ps -aq') printf '%s\n' a b c d e f ;;
  'inspect -f')
    printf '/web\x1fnginx:stable-alpine\x1fsha256:i1\n'
    printf '/web2\x1fnginx:stable-alpine\x1fsha256:i1\n'
    printf '/den-watcher\x1fghcr.io/programmer-den/den-watcher:main\x1fsha256:i2\n'
    printf '/built\x1fteamspeak-usage\x1fsha256:i3\n'
    printf '/pinned\x1fbusybox@$d1\x1fsha256:i4\n'
    printf '/private\x1fghcr.io/me/private:1\x1fsha256:i5\n' ;;
  'image inspect')
    case "\${*: -1}" in
      sha256:i1) printf 'nginx@$d1 ' ;;
      sha256:i2) printf 'ghcr.io/programmer-den/den-watcher@$d1 ' ;;
      sha256:i4) printf 'busybox@$d1 ' ;;
      sha256:i5) printf 'ghcr.io/me/private@$d3 ' ;;
    esac ;;
esac
EOF
# Registries: a token first (behind a proxy), then the digest of the tag.
cat >"$ubin/curl" <<EOF
#!/usr/bin/env bash
url="\${*: -1}"
echo "\$url \$*" >>"\${0%/*}/curl.log"
case "\$url" in
  https://auth.docker.io/token|https://ghcr.io/token) echo '{"token":"t0k"}'; exit ;;
esac
if [[ "\$*" != *'Bearer t0k'* ]]; then
  realm=https://auth.docker.io/token
  [[ "\$url" != https://ghcr.io/* ]] || realm=https://ghcr.io/token
  printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 401\r\nwww-authenticate: Bearer realm="%s",service="reg",scope="repository:x:pull"\r\n\r\n' "\$realm"
  exit
fi
case "\$url" in
  https://registry-1.docker.io/v2/library/nginx/manifests/stable-alpine) d=$d1 ;;
  https://ghcr.io/v2/programmer-den/den-watcher/manifests/main) d=$d2 ;;
  *) printf 'HTTP/2 403\r\n\r\n'; exit ;;
esac
printf 'HTTP/2 200\r\nDocker-Content-Digest: %s\r\n\r\n' "\$d"
EOF
cat >"$ubin/apt-get" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  update) echo update >>"${0%/*}/apt.log" ;;
  -s) printf '%s\n' 'Reading package lists...' \
    'Inst libssl3 [3.0.1] (3.0.2 Debian-Security:12/stable-security [arm64])' \
    'Inst curl [7.88.1-10] (7.88.1-11 Debian:12.5/stable [arm64])' \
    'Conf libssl3 (3.0.2 Debian-Security:12/stable-security [arm64])' ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$ubin/pihole"
cat >"$ubin/rpi-eeprom-update" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'BOOTLOADER: update available' '   CURRENT: Mon 22 Jan 10:41:21 UTC 2024 (1705920081)' \
  '    LATEST: Thu 10 Oct 12:00:00 UTC 2024 (1728561600)' '   RELEASE: default' '' \
  '   VL805_FW: Using bootloader EEPROM' '     VL805: up to date' '   CURRENT: 000138c0 (1)'
exit 1
EOF
chmod +x "$ubin"/*
printf '%s\n' "CORE_VERSION='v6.1'" "GITHUB_CORE_VERSION='v6.2'" 'WEB_VERSION=v6.2' 'GITHUB_WEB_VERSION=v6.2' \
  'FTL_VERSION=v6.1' 'GITHUB_FTL_VERSION=' >"$TMP/pihole-versions"

# rpi-setup itself: a clone of a local "upstream" repository.
gitq() { git -c user.name=Sam -c user.email=sam@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
gitq init -q --bare "$TMP/upstream.git"
gitq clone -q "$TMP/upstream.git" "$TMP/checkout"
gitq -C "$TMP/checkout" commit -q --allow-empty -m one
gitq -C "$TMP/checkout" push -q -u origin HEAD:main
head="$(git -C "$TMP/checkout" rev-parse --short=7 HEAD)"

run_updates() { PATH="$ubin:$PATH" WU_PIHOLE_VERSIONS="$TMP/pihole-versions" bash "$TMP/updates"; }
assert_ok "updates: runs" run_updates
updates="$(cat "$TMP/html/updates.json" 2>/dev/null || true)"
if command -v python3 >/dev/null 2>&1; then
  summary="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("checked" if d["checked"].endswith("Z") else d["checked"])
for u in d["items"]:
    extra = u.get("image") or u.get("branch") or ""
    if u["kind"] == "apt":
        extra = "%s %s %s" % (u["count"], u["security"], ",".join(u["packages"]))
    print("%s|%s|%s|%s|%s|%s" % (u["name"], u["kind"], u["current"][:12], u["latest"][:12], u["update"], extra))
' "$TMP/html/updates.json" 2>&1)" || summary="not JSON: $summary"
  expected="checked
rpi-setup|git|$head|$head|False|main
Pi-hole|pihole|Core v6.1, W|Core v6.2, W|True|
EEPROM firmware|eeprom|Mon 22 Jan 1|Thu 10 Oct 1|True|
den-watcher|container|sha256:11111|sha256:22222|True|ghcr.io/programmer-den/den-watcher:main
private|container|sha256:33333||None|ghcr.io/me/private:1
web|container|sha256:11111|sha256:11111|False|nginx:stable-alpine
web2|container|sha256:11111|sha256:11111|False|nginx:stable-alpine
OS packages|apt|||True|2 1 libssl3,curl"
  assert_eq "updates: rpi-setup, Pi-hole, the bootloader, the containers by name and the OS packages" "$expected" "$summary"
else
  skip "updates: python3 not installed"
fi
assert_contains "updates: a Pi-hole part without a newest version is left out" '"latest":"Core v6.2, Web v6.2"' "$updates"
assert_eq "updates: each image is asked once" 1 "$(grep -c 'nginx/manifests/stable-alpine .*Bearer' "$ubin/curl.log")"
assert_eq "updates: the package lists are refreshed first" update "$(cat "$ubin/apt.log" 2>/dev/null)"
assert_lacks "updates: an image built on the Pi is left out" '"built"' "$updates"
assert_lacks "updates: an image pinned by digest is left out" '"pinned"' "$updates"

gitq clone -q "$TMP/upstream.git" "$TMP/other"
gitq -C "$TMP/other" commit -q --allow-empty -m two
gitq -C "$TMP/other" push -q origin main
latest="$(git -C "$TMP/other" rev-parse --short=7 HEAD)"
run_updates
assert_contains "updates: a newer commit upstream is an update" \
  "\"name\":\"rpi-setup\",\"kind\":\"git\",\"current\":\"$head\",\"latest\":\"$latest\",\"update\":true" \
  "$(cat "$TMP/html/updates.json")"
gitq -C "$TMP/checkout" pull -q
gitq -C "$TMP/checkout" commit -q --allow-empty -m three
run_updates
assert_contains "updates: a checkout ahead of upstream is up to date" '"latest":"'"$latest"'","update":false' \
  "$(grep '"kind":"git"' "$TMP/html/updates.json")"

printf '#!/usr/bin/env bash\nexit 1\n' >"$ubin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ubin/apt-get"
rm -f "$ubin/pihole" "$ubin/rpi-eeprom-update"
RPI_SETUP_ROOT="$TMP/no-checkout"
web_updates_script "$TMP/html/updates.json" >"$TMP/updates"
assert_ok "updates: runs without Docker, Pi-hole, a bootloader or a checkout" run_updates
assert_eq "updates: then only the OS packages, all current" \
  $'{"name":"OS packages","kind":"apt","current":"","latest":"","update":false,"count":0,"security":0,"packages":[]}\n]}' \
  "$(sed '1d' "$TMP/html/updates.json")"

finish_tests
