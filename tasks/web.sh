#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
# Settings: WEB_* in config/rpi-setup.env (names in config/tasks/web.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("web|nginx with a start page linking the web pages on this Pi (:80 or :8080)")

run_web() {
  : "${WEB_TITLE:=Raspberry Pi}" "${WEB_DOCKER:=no}"
  [[ -z "${WEB_PORT:-}" ]] || require_port WEB_PORT
  [[ "$WEB_TITLE" != *[\<\>\&]* ]] || die "WEB_TITLE cannot contain <, > or & (got '$WEB_TITLE')"
  if setting_on WEB_DOCKER; then run_web_container; return; fi
  container_leave web
  local site=/etc/nginx/sites-available/default owner="" want="${WEB_PORT:-}" cur

  if ! apt_installed nginx; then
    owner="$(port_owner 80)" || owner=""
    if [[ -n "$owner" ]]; then
      # Something else (usually Pi-hole's web UI) holds port 80. nginx's
      # postinst would fail to start on it and abort the install, so keep the
      # service down during install and move the default site elsewhere.
      [[ -n "$want" ]] || want=8080
      info "Port 80 is used by '$owner'; nginx will listen on $want instead"
      local own_policy=0
      if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
        chmod 0755 /usr/sbin/policy-rc.d
        own_policy=1
      fi
      local rc=0
      apt_install nginx || rc=$?
      [[ $own_policy -eq 0 ]] || rm -f /usr/sbin/policy-rc.d
      [[ $rc -eq 0 ]] || die 'nginx install failed'
    else
      apt_install nginx
    fi
  fi

  cur="$(nginx_site_port "$site")"
  if [[ -n "$want" && -n "$cur" && "$want" != "$cur" ]]; then
    owner="$(port_owner "$want")" || owner=""
    if [[ -n "$owner" && "$owner" != nginx ]]; then
      die "WEB_PORT=$want is already used by '$owner'; pick another port"
    fi
    nginx_move_port "$site" "$cur" "$want"
    info "nginx moved from port $cur to $want"
  fi

  web_index_page /var/www/html/index.html
  web_links_install /var/www/html

  nginx -t -q || die "nginx configuration test failed; check $site"
  systemctl enable --now nginx
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  say "nginx running - open $(service_url "$(nginx_site_port "$site")") in your browser"
}

# The page is (re)written while it is ours or missing; a page you put there
# yourself is never overwritten. Either way the service list next to it
# (services.json) is kept up to date by web_links_install.
web_index_page() {
  local f="$1" page
  if [[ -f "$f" ]] && ! grep -q 'rpi-setup' "$f"; then
    info "$f is your own page; leaving it alone"
    return
  fi
  page="$(web_index_html)"
  printf '%s\n' "${page//@TITLE@/"$WEB_TITLE"}" | write_if_changed "$f" 0644 || true
}

# The start page, with @TITLE@ for WEB_TITLE. It follows the browser's light
# or dark setting and lists the web pages from services.json (re-read every
# 30 seconds), linked on the address the page was opened with.
web_index_html() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>@TITLE@</title>
<style>
  :root {
    --bg: #f6f7f9; --card: #ffffff; --text: #1d2330; --muted: #5d6677;
    --border: #dfe3ea; --accent: #c51a4a; --up: #1f9d55; --down: #b4262e;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #12151b; --card: #1b2029; --text: #e7eaf0; --muted: #9aa3b2;
      --border: #2c3340; --accent: #ff5c86; --up: #3ccf7f; --down: #ff6b6b;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; background: var(--bg); color: var(--text);
    font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  main { max-width: 960px; margin: 0 auto; padding: 48px 16px; }
  h1 { margin: 0; font-size: 2rem; }
  .host { margin: 4px 0 32px; color: var(--muted); }
  .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
  .card {
    display: block; padding: 18px 20px; border: 1px solid var(--border); border-radius: 12px;
    background: var(--card); color: inherit; text-decoration: none;
    transition: border-color .15s, transform .15s;
  }
  .card:hover, .card:focus-visible { border-color: var(--accent); transform: translateY(-2px); }
  .name { display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 1.1rem; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); flex: none; }
  .dot.up { background: var(--up); }
  .dot.down { background: var(--down); }
  .desc { margin: 6px 0 10px; color: var(--muted); font-size: .95rem; }
  .addr { color: var(--accent); font-size: .9rem; word-break: break-all; }
  .note { color: var(--muted); }
  footer { margin-top: 48px; color: var(--muted); font-size: .85rem; }
  footer a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>@TITLE@</h1>
  <p class="host" id="host"></p>
  <div class="grid" id="services"></div>
  <p class="note" id="note">Looking for web pages on this Pi...</p>
  <noscript><p class="note">Turn on JavaScript to see the web pages on this Pi.</p></noscript>
  <footer>Provisioned by <a href="https://github.com/Chriszly/rpi-setup">rpi-setup</a>.
    New services show up here on their own within a minute.</footer>
</main>
<script>
(function () {
  var grid = document.getElementById('services');
  var note = document.getElementById('note');
  var host = document.getElementById('host');

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  function link(s) {
    var port = Number(s.port) === 80 ? '' : ':' + s.port;
    return 'http://' + location.hostname + port + (s.path || '/');
  }

  function render(data) {
    var list = Array.isArray(data.services) ? data.services : [];
    if (data.host) host.textContent = data.host;
    grid.textContent = '';
    list.forEach(function (s) {
      var a = el('a', 'card');
      a.href = link(s);
      var name = el('div', 'name');
      var dot = el('span', 'dot' + (s.up === true ? ' up' : s.up === false ? ' down' : ''));
      dot.title = s.up === true ? 'answering' : s.up === false ? 'not answering' : '';
      name.appendChild(dot);
      name.appendChild(document.createTextNode(s.name));
      a.appendChild(name);
      if (s.description) a.appendChild(el('div', 'desc', s.description));
      a.appendChild(el('div', 'addr', a.href.replace(/^http:\/\//, '')));
      grid.appendChild(a);
    });
    note.textContent = list.length ? '' : 'No other web pages on this Pi yet.';
  }

  function load() {
    fetch('services.json', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(render)
      .catch(function () { note.textContent = 'The list of web pages is not ready yet; it is retried every 30 seconds.'; });
  }

  load();
  setInterval(load, 30000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) load(); });
})();
</script>
</body>
</html>
HTML
}

# --- Service list (services.json for the start page) ----------------------

RPI_WEB_LINKS_SCRIPT=/usr/local/sbin/rpi-setup-web-links
RPI_WEB_LINKS_UNIT=rpi-setup-web-links

# Install the script that writes $1/services.json and a timer that runs it
# every minute, then write the list once now.
web_links_install() {
  local out="$1/services.json" units=0
  install -m 0755 -d "$(dirname "$RPI_WEB_LINKS_SCRIPT")"
  web_links_script "$out" | write_if_changed "$RPI_WEB_LINKS_SCRIPT" 0755 || true
  printf '%s\n' \
    '[Unit]' \
    'Description=List the web pages on this Pi for the start page (tasks/web.sh)' \
    'After=docker.service pihole-FTL.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$RPI_WEB_LINKS_SCRIPT" \
    'Nice=10' \
    'PrivateTmp=yes' \
    'ProtectHome=read-only' \
    'NoNewPrivileges=yes' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_LINKS_UNIT.service" && units=1
  printf '%s\n' \
    '[Unit]' \
    'Description=Refresh the start page service list every minute' \
    '' \
    '[Timer]' \
    'OnBootSec=30s' \
    'OnUnitActiveSec=1min' \
    'AccuracySec=10s' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' |
    write_if_changed "/etc/systemd/system/$RPI_WEB_LINKS_UNIT.timer" && units=1
  if [[ $units -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart "$RPI_WEB_LINKS_UNIT.timer" 2>/dev/null || true
  fi
  systemctl enable --now "$RPI_WEB_LINKS_UNIT.timer"
  "$RPI_WEB_LINKS_SCRIPT" || warn "Could not write $out yet; the timer tries again every minute"
}

# Print the standalone service list script writing to $1: the web_links_run_*
# functions below plus the helpers they use from lib/common.sh, so the unit
# tests exercise the very code the timer runs.
web_links_script() {
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/web.sh): lists the web pages on this Pi for\n'
  printf '# the start page. Re-run "sudo bash setup.sh web" instead of editing this file.\n'
  printf 'set -euo pipefail\n'
  printf 'WL_OUT=%q\n' "$1"
  declare -f have container_dir task_in_container pihole_ftl pihole_web_ports write_if_changed \
    web_links_run_json web_links_run_known web_links_run_ports web_links_run_http \
    web_links_run_entry web_links_run_list web_links_run
  printf 'web_links_run\n'
}

# --- Code of the service list script (uses only WL_* variables, plain tools
# and the lib/common.sh helpers named in web_links_script) ----------------

# $1 as a JSON string: quotes and backslashes escaped, control characters
# dropped.
web_links_run_json() {
  local s="${1//[[:cntrl:]]/}"
  s="${s//\\/\\\\}"
  printf '"%s"' "${s//\"/\\\"}"
}

# Name, description and path (tab separated) of a container an rpi-setup task
# runs, "-" for one that is not a web page (or listed on its own), or exit 1
# for any other container.
web_links_run_known() {
  case "$1" in
    netalertx) printf 'NetAlertX\tWhich devices are on the network, and when\t/\n' ;;
    usage-control) printf 'usage-control\tCPU, memory and temperature of this Pi\t/\n' ;;
    pihole|web|teamspeak|samba) printf -- '-\n' ;;
    *) return 1 ;;
  esac
}

# TCP ports container $1 offers on the LAN, one per line: the ports Docker
# publishes (not those bound to localhost only), and for NetAlertX on the
# host network its PORT setting.
web_links_run_ports() {
  if [[ "$1" == netalertx ]]; then
    sed -nE 's/^[[:space:]]*PORT:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' \
      "$(container_dir netalertx)/docker-compose.yml" 2>/dev/null | head -n1
    return 0
  fi
  docker port "$1" 2>/dev/null |
    sed -nE '/-> (127\.|\[::1\])/d; s#^[0-9]+/tcp -> .*:([0-9]+)$#\1#p' | awk '!seen[$0]++'
}

# HTTP status code of http://127.0.0.1:$1$2, "000" when nothing answers.
web_links_run_http() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 \
    "http://127.0.0.1:$1${2%%#*}" 2>/dev/null)" || true
  printf '%s\n' "${code:-000}"
}

# Print one service as a JSON object: name $1, description $2, port $3, path
# $4. With $5=probe it is listed only if it answers HTTP. Returns 1 if it was
# left out: a bad port, a port already listed, or no answer to a probe. Uses
# the caller's "seen" and "sep".
web_links_run_entry() {
  local name="${1:0:60}" desc="${2:0:160}" port="$3" path="${4:-/}" mode="${5:-}" up=null code
  local path_re='^/[A-Za-z0-9._~/?#=&%:@+,;!-]*$'
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  port=$((10#$port))
  [[ -z "${seen[$port]:-}" ]] || return 1
  [[ "$path" =~ $path_re ]] || path=/
  if have curl; then
    code="$(web_links_run_http "$port" "$path")"
    if [[ "$code" == 000 ]]; then up=false; else up=true; fi
  fi
  [[ "$mode" != probe || "$up" != false ]] || return 1
  seen[$port]=1
  printf '%s{"name":%s,"description":%s,"port":%s,"path":%s,"up":%s}' "$sep" \
    "$(web_links_run_json "$name")" "$(web_links_run_json "$desc")" "$port" \
    "$(web_links_run_json "$path")" "$up"
  sep=$',\n'
}

# Print services.json: Pi-hole (in its container or on the host), then every
# running container, sorted by name. A container's rpi-setup.link.* labels
# win; rpi-setup's own containers have a name and description; any other
# container is listed with the first published port that answers HTTP.
web_links_run_list() {
  local -A seen=()
  local sep="" name port known title desc path hide lport lname lpath ldesc fmt
  printf '{"host":%s,"services":[\n' "$(web_links_run_json "$(hostname 2>/dev/null || true)")"
  if task_in_container pihole || systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    port="$(pihole_web_ports | head -n1)"
    [[ -z "$port" ]] ||
      web_links_run_entry Pi-hole 'Blocks ads and trackers for every device on the network' "$port" /admin/ || true
  fi
  if have docker && docker info >/dev/null 2>&1; then
    fmt=$'{{index .Config.Labels "rpi-setup.link"}}\x1f{{index .Config.Labels "rpi-setup.link.port"}}\x1f'
    fmt+=$'{{index .Config.Labels "rpi-setup.link.name"}}\x1f{{index .Config.Labels "rpi-setup.link.path"}}\x1f'
    fmt+='{{index .Config.Labels "rpi-setup.link.description"}}'
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      hide="" lport="" lname="" lpath="" ldesc=""
      IFS=$'\x1f' read -r hide lport lname lpath ldesc \
        < <(docker inspect -f "$fmt" "$name" 2>/dev/null | head -n1 | sed 's/<no value>//g') || true
      [[ ! "${hide,,}" =~ ^(no|off|false|0)$ ]] || continue
      if [[ -n "$lport" ]]; then
        web_links_run_entry "${lname:-$name}" "$ldesc" "$lport" "${lpath:-/}" || true
        continue
      fi
      if known="$(web_links_run_known "$name")"; then
        [[ "$known" != - ]] || continue
        IFS=$'\t' read -r title desc path <<<"$known"
        port="$(web_links_run_ports "$name" | head -n1)"
        web_links_run_entry "$title" "$desc" "$port" "$path" || true
        continue
      fi
      for port in $(web_links_run_ports "$name"); do
        ! web_links_run_entry "$name" '' "$port" / probe || break
      done
    done < <(docker ps --format '{{.Names}}' 2>/dev/null | sort)
  fi
  printf '\n]}\n'
}

# Write the list to $WL_OUT; the file only changes when the list does.
web_links_run() {
  web_links_run_list | write_if_changed "$WL_OUT" 0644 || true
}

# The IPv4 port of the default site's first "listen" line, e.g. "80".
nginx_site_port() {
  sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:];]).*/\1/p' "$1" 2>/dev/null | head -n1
}

# Change the IPv4 and IPv6 "listen <from>" lines of an nginx site to <to>.
nginx_move_port() {
  local site="$1" from="$2" to="$3"
  sed -Ei "s/^([[:space:]]*listen[[:space:]]+(\\[::\\]:)?)${from}([[:space:];])/\\1${to}\\3/" "$site"
}

# WEB_DOCKER=yes: nginx in its own container (host network), serving
# /opt/web/html with the site config from /opt/web/conf. A native nginx is
# stopped and its /var/www/html copied over once.
run_web_container() {
  : "${WEB_IMAGE:=nginx:stable-alpine}"
  local dir name=web port="${WEB_PORT:-}" owner="" changed=0 native=/etc/nginx/sites-available/default
  require_image_ref WEB_IMAGE
  container_require_64bit WEB_DOCKER
  container_require_docker
  dir="$(container_dir web)"

  # Port: WEB_PORT, else the one used so far (container or native nginx),
  # else 80, or 8080 when something other than nginx (Pi-hole) holds 80.
  if [[ -z "$port" ]]; then
    # nginx_site_port fails (sed: no such file) when the file is missing.
    port="$(nginx_site_port "$dir/conf/default.conf" || true)"
    [[ -n "$port" ]] || port="$(nginx_site_port "$native" || true)"
    if [[ -z "$port" ]]; then
      port=80
      owner="$(port_owner 80)" || owner=""
      [[ -z "$owner" || "$owner" == nginx ]] || port=8080
    fi
  fi
  owner="$(port_owner "$port")" || owner=""
  [[ -z "$owner" || "$owner" == nginx ]] ||
    die "Port $port is already used by '$owner'; set WEB_PORT to a free port"

  install -m 0755 -d "$dir" "$dir/conf" "$dir/html"
  if web_container_compose "$dir" "$name" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  if web_container_site "$port" | write_if_changed "$dir/conf/default.conf" 0644; then changed=1; fi
  container_pull "$dir"

  container_copy_once "$dir" /var/www/html "$dir/html" || true
  web_index_page "$dir/html/index.html"
  web_links_install "$dir/html"
  local extra=""
  if [[ -d /etc/nginx/sites-enabled ]]; then
    extra="$(find /etc/nginx/sites-enabled -mindepth 1 ! -name default -printf '%f ' 2>/dev/null)" || extra=""
  fi
  [[ -z "$extra" ]] || warn "Native nginx sites not carried over: ${extra}(add them to $dir/conf)"
  container_stop_native "$dir" nginx

  # The site config is a bind mount; nginx reads it at start.
  container_up "$dir" "$name" "$changed"
  say "nginx container running - open $(service_url "$port") in your browser (files in $dir/html)"
}

# nginx site for the container, listening on port $1 (IPv6 too where the
# host has it; nginx will not start on a missing address family).
web_container_site() {
  local v6=""
  # /proc files report size 0, so test the content, not -s.
  [[ -z "$(cat /proc/net/if_inet6 2>/dev/null)" ]] || v6="    listen [::]:$1;"
  cat <<EOF
# Managed by rpi-setup (tasks/web.sh, WEB_* settings).
server {
    listen $1;
${v6}
    server_name _;
    root /usr/share/nginx/html;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# Compose file of the web container in folder $1, container name $2: no
# privilege escalation, a process limit and only the capabilities nginx
# needs to bind its port and drop to its own user.
web_container_compose() {
  local dir="$1" name="$2"
  cat <<EOF
services:
  web:
    image: "$WEB_IMAGE"
    container_name: $name
    restart: unless-stopped
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
    network_mode: host
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /run
      - /tmp
    environment:
      NGINX_ENTRYPOINT_QUIET_LOGS: "1"
    volumes:
      - type: bind
        source: $dir/html
        target: /usr/share/nginx/html
        read_only: true
      - type: bind
        source: $dir/conf
        target: /etc/nginx/conf.d
        read_only: true
EOF
}
