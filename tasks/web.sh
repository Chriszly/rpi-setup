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
  web_links_refresh

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
# or dark setting, lists the web pages from services.json, linked on the
# address the page was opened with, and the Docker containers from
# containers.json (both re-read every 30 seconds).
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
    --border: #dfe3ea; --accent: #c51a4a; --up: #1f9d55; --down: #b4262e; --wait: #b7791f;
    --chart: #c51a4a;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #12151b; --card: #1b2029; --text: #e7eaf0; --muted: #9aa3b2;
      --border: #2c3340; --accent: #ff5c86; --up: #3ccf7f; --down: #ff6b6b; --wait: #f0b429;
      --chart: #f0457a;
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
  .dot.wait { background: var(--wait); }
  .desc { margin: 6px 0 10px; color: var(--muted); font-size: .95rem; }
  .addr { color: var(--accent); font-size: .9rem; word-break: break-all; }
  .note { color: var(--muted); }
  h2 { margin: 40px 0 12px; font-size: 1.25rem; }
  .list { border: 1px solid var(--border); border-radius: 12px; background: var(--card); }
  .row {
    display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 2fr) minmax(0, 1fr);
    gap: 4px 16px; align-items: center; padding: 10px 16px;
  }
  .row + .row { border-top: 1px solid var(--border); }
  .row .name { font-size: 1rem; }
  .image, .ports { color: var(--muted); font-size: .9rem; overflow-wrap: anywhere; }
  .ports { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .85rem; }
  .state { color: var(--muted); font-size: .9rem; text-align: right; }
  @media (max-width: 600px) {
    .row { grid-template-columns: minmax(0, 1fr) auto; }
    .row .image { grid-column: 1 / -1; grid-row: 2; }
    .row .state { grid-row: 1; grid-column: 2; }
  }
  .ts-online { margin: 0 0 12px; }
  .chart {
    position: relative; margin-bottom: 16px; padding: 12px 16px 8px;
    border: 1px solid var(--border); border-radius: 12px; background: var(--card);
  }
  .chart-head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 16px; font-size: .9rem; }
  .chart-head .peak { color: var(--muted); }
  .chart svg { display: block; width: 100%; height: 180px; margin-top: 8px; touch-action: pan-y; }
  .chart .grid { stroke: var(--border); stroke-width: 1; }
  .chart .axis { fill: var(--muted); font-size: 11px; }
  .chart .area { fill: var(--chart); fill-opacity: .1; }
  .chart .line { fill: none; stroke: var(--chart); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .chart .cursor { stroke: var(--muted); stroke-width: 1; }
  .chart .mark { fill: var(--chart); stroke: var(--card); stroke-width: 2; }
  .tip {
    position: absolute; top: 0; pointer-events: none; padding: 4px 8px; border-radius: 6px;
    background: var(--text); color: var(--bg); font-size: .85rem; white-space: nowrap;
    transform: translate(-50%, -100%);
  }
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
  <section id="docker" hidden>
    <h2>Docker containers</h2>
    <div class="list" id="containers"></div>
  </section>
  <section id="ts" hidden>
    <h2>TeamSpeak</h2>
    <p class="ts-online" id="ts-online"></p>
    <div class="chart" id="ts-chart" hidden>
      <div class="chart-head"><span>Online at the same time, last 7 days</span><span class="peak" id="ts-peak"></span></div>
      <svg id="ts-svg" role="img"></svg>
      <div class="tip" id="ts-tip" hidden></div>
    </div>
    <div class="list" id="ts-users"></div>
    <h2>Last visits</h2>
    <div class="list" id="ts-recent"></div>
  </section>
  <noscript><p class="note">Turn on JavaScript to see the web pages on this Pi.</p></noscript>
  <footer>Provisioned by <a href="https://github.com/Chriszly/rpi-setup">rpi-setup</a>.
    New services and containers show up here on their own within a minute.</footer>
</main>
<script>
(function () {
  var grid = document.getElementById('services');
  var note = document.getElementById('note');
  var host = document.getElementById('host');
  var docker = document.getElementById('docker');
  var rows = document.getElementById('containers');
  var ts = document.getElementById('ts');

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
    host.textContent = [data.host, data.ip].filter(Boolean).join(' \u00b7 ');
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

  // "45 s", "12 min", "3 h", "2 d" since the ISO time t, or "" if unknown.
  function since(t) {
    var s = Math.floor((Date.now() - Date.parse(t)) / 1000);
    if (!t || isNaN(s)) return '';
    s = Math.max(s, 0);
    if (s < 60) return s + ' s';
    if (s < 3600) return Math.floor(s / 60) + ' min';
    if (s < 86400) return Math.floor(s / 3600) + ' h';
    return Math.floor(s / 86400) + ' d';
  }

  function containerState(c) {
    var restarts = c.restarts > 0 ? ', ' + c.restarts + (c.restarts === 1 ? ' restart' : ' restarts') : '';
    if (c.state === 'running') {
      var up = since(c.started);
      var health = c.health && c.health !== 'healthy' ? c.health + ', ' : '';
      return {
        dot: c.health === 'unhealthy' ? 'down' : c.health === 'starting' ? 'wait' : 'up',
        text: health + (up ? 'up ' + up : 'running') + restarts
      };
    }
    if (c.state === 'restarting') return { dot: 'wait', text: 'restarting' + restarts };
    var ago = since(c.finished);
    return { dot: c.state === 'created' ? '' : 'down', text: c.state + (ago ? ' ' + ago + ' ago' : '') };
  }

  function renderContainers(data) {
    var list = Array.isArray(data.containers) ? data.containers : [];
    docker.hidden = !list.length;
    rows.textContent = '';
    list.forEach(function (c) {
      var st = containerState(c);
      var row = el('div', 'row');
      var name = el('div', 'name');
      var dot = el('span', 'dot' + (st.dot ? ' ' + st.dot : ''));
      dot.title = c.state + (c.health ? ', ' + c.health : '');
      name.appendChild(dot);
      name.appendChild(document.createTextNode(c.name));
      row.appendChild(name);
      var image = el('div', 'image', c.image);
      var ports = (c.ports || []).join(' ') || (c.network === 'host' ? 'host network' : '');
      if (ports) image.appendChild(el('div', 'ports', ports));
      row.appendChild(image);
      row.appendChild(el('div', 'state', st.text));
      rows.appendChild(row);
    });
  }

  // "<1 min", "12 min", "3 h 5 min", "2 d 4 h" for s seconds.
  function duration(s) {
    var m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
    if (m < 1) return '<1 min';
    if (h < 1) return m + ' min';
    if (d < 1) return h + ' h' + (m % 60 ? ' ' + m % 60 + ' min' : '');
    return d + ' d' + (h % 24 ? ' ' + h % 24 + ' h' : '');
  }

  function clock(t, day) {
    var o = { hour: '2-digit', minute: '2-digit' };
    if (day) { o.weekday = 'short'; o.day = 'numeric'; o.month = 'short'; }
    return new Date(t).toLocaleString([], o);
  }

  function tsRow(list, nick, online, middle, right) {
    var row = el('div', 'row');
    var name = el('div', 'name');
    var dot = el('span', 'dot' + (online ? ' up' : ''));
    dot.title = online ? 'online' : 'offline';
    name.appendChild(dot);
    name.appendChild(document.createTextNode(nick));
    row.appendChild(name);
    row.appendChild(el('div', 'image', middle));
    row.appendChild(el('div', 'state', right));
    list.appendChild(row);
  }

  // Step chart of how many were online at once: points are [epoch seconds,
  // count] where the count changes, from 7 days ago to now.
  var chart = document.getElementById('ts-chart');
  var svg = document.getElementById('ts-svg');
  var tip = document.getElementById('ts-tip');
  var pts = [], scale = null;

  function countAt(t) {
    var c = 0;
    for (var i = 0; i < pts.length && pts[i][0] <= t; i++) c = pts[i][1];
    return c;
  }

  function drawChart() {
    if (pts.length < 2 || chart.hidden) return;
    var W = svg.clientWidth || 600, H = 180, L = 28, R = 6, T = 8, B = 22;
    var t0 = pts[0][0], t1 = pts[pts.length - 1][0], max = 1, i, c, out = '';
    pts.forEach(function (p) { max = Math.max(max, p[1]); });
    var step = Math.ceil(max / 4), top = Math.ceil(max / step) * step;
    var x = function (t) { return L + (t - t0) / Math.max(t1 - t0, 1) * (W - L - R); };
    var y = function (n) { return T + (1 - n / top) * (H - T - B); };
    scale = { x: x, y: y, t0: t0, t1: t1, L: L, R: R, W: W };
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    for (c = 0; c <= top; c += step) {
      out += '<line class="grid" x1="' + L + '" x2="' + (W - R) + '" y1="' + y(c) + '" y2="' + y(c) + '"/>';
      out += '<text class="axis" x="' + (L - 8) + '" y="' + (y(c) + 4) + '" text-anchor="end">' + c + '</text>';
    }
    // A day name under the middle of each day.
    var d = new Date(t0 * 1000);
    d.setHours(12, 0, 0, 0);
    for (; d.getTime() / 1000 <= t1; d.setDate(d.getDate() + 1)) {
      var noon = d.getTime() / 1000;
      if (noon < t0) continue;
      out += '<text class="axis" x="' + x(noon) + '" y="' + (H - 4) + '" text-anchor="middle">' +
        d.toLocaleDateString([], { weekday: 'short' }) + '</text>';
    }
    var line = 'M' + x(t0) + ' ' + y(pts[0][1]);
    for (i = 1; i < pts.length; i++) line += 'H' + x(pts[i][0]) + 'V' + y(pts[i][1]);
    out += '<path class="area" d="' + line + 'V' + y(0) + 'H' + x(t0) + 'Z"/>';
    out += '<path class="line" d="' + line + '"/>';
    out += '<line class="cursor" id="ts-cursor" y1="' + T + '" y2="' + y(0) + '" visibility="hidden"/>';
    out += '<circle class="mark" id="ts-mark" r="4" visibility="hidden"/>';
    svg.innerHTML = out;
  }

  function hover(ev) {
    if (!scale) return;
    var r = svg.getBoundingClientRect();
    var px = Math.min(Math.max((ev.touches ? ev.touches[0] : ev).clientX - r.left, scale.L), scale.W - scale.R);
    var t = scale.t0 + (px - scale.L) / (scale.W - scale.L - scale.R) * (scale.t1 - scale.t0);
    var n = countAt(t), cur = document.getElementById('ts-cursor'), mark = document.getElementById('ts-mark');
    cur.setAttribute('x1', px); cur.setAttribute('x2', px); cur.setAttribute('visibility', 'visible');
    mark.setAttribute('cx', px); mark.setAttribute('cy', scale.y(n)); mark.setAttribute('visibility', 'visible');
    tip.textContent = clock(t * 1000, true) + ' \u00b7 ' + n + ' online';
    tip.hidden = false;
    // Centered over the cursor, but kept inside the chart box.
    var box = chart.getBoundingClientRect(), half = tip.offsetWidth / 2;
    tip.style.left = Math.min(Math.max(r.left - box.left + px, half), box.width - half) + 'px';
    tip.style.top = (r.top - box.top + scale.y(n) - 8) + 'px';
  }

  function unhover() {
    tip.hidden = true;
    ['ts-cursor', 'ts-mark'].forEach(function (id) {
      var e = document.getElementById(id);
      if (e) e.setAttribute('visibility', 'hidden');
    });
  }

  svg.addEventListener('mousemove', hover);
  svg.addEventListener('touchstart', hover, { passive: true });
  svg.addEventListener('touchmove', hover, { passive: true });
  svg.addEventListener('mouseleave', unhover);
  svg.addEventListener('touchend', unhover);
  window.addEventListener('resize', drawChart);

  function renderChart(points) {
    pts = (Array.isArray(points) ? points : []).filter(function (p) {
      return Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);
    });
    chart.hidden = pts.length < 2;
    if (chart.hidden) return;
    var peak = pts[0];
    pts.forEach(function (p) { if (p[1] > peak[1]) peak = p; });
    var text = peak[1] ? 'Peak: ' + peak[1] + ' online, ' + clock(peak[0] * 1000, true)
      : 'Nobody was online in the last 7 days.';
    document.getElementById('ts-peak').textContent = text;
    svg.setAttribute('aria-label', 'How many people were online at the same time over the last 7 days. ' + text);
    unhover();
    drawChart();
  }

  // Who is on the TeamSpeak server, time online per person over the last 7
  // days, and the last visits, from teamspeak.json.
  function renderTeamspeak(data) {
    var online = Array.isArray(data.online) ? data.online : [];
    var users = Array.isArray(data.users) ? data.users : [];
    var recent = Array.isArray(data.recent) ? data.recent : [];
    var listUsers = document.getElementById('ts-users');
    var listRecent = document.getElementById('ts-recent');
    ts.hidden = false;
    renderChart(data.concurrent);
    document.getElementById('ts-online').textContent = online.length
      ? 'Online now: ' + online.map(function (c) { return c.nick + ' (' + since(c.since) + ')'; }).join(', ')
      : 'Nobody is online right now.';
    listUsers.textContent = '';
    listUsers.hidden = !users.length;
    users.forEach(function (u) {
      var visits = u.week_visits + (u.week_visits === 1 ? ' visit' : ' visits');
      tsRow(listUsers, u.nick, u.online, duration(u.week_seconds) + ' in the last 7 days, ' + visits,
        u.online ? 'online now' : 'seen ' + since(u.last_seen) + ' ago');
    });
    listRecent.textContent = '';
    listRecent.hidden = listRecent.previousElementSibling.hidden = !recent.length;
    recent.forEach(function (v) {
      var secs = (Date.parse(v.end) - Date.parse(v.start)) / 1000;
      tsRow(listRecent, v.nick, false, clock(v.start, true) + ' \u2013 ' + clock(v.end, false), duration(secs));
    });
  }

  function get(file, done, failed) {
    fetch(file, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(done)
      .catch(failed);
  }

  function load() {
    get('services.json', render, function () {
      note.textContent = 'The list of web pages is not ready yet; it is retried every 30 seconds.';
    });
    get('containers.json', renderContainers, function () { docker.hidden = true; });
    get('teamspeak.json', renderTeamspeak, function () { ts.hidden = true; });
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

# Install the script that writes $1/services.json and $1/containers.json, and
# a timer that runs it every minute.
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
}

# Write the lists now, once the services are up, instead of within a minute.
web_links_refresh() {
  "$RPI_WEB_LINKS_SCRIPT" || warn "Could not write the lists for the start page yet; the timer tries again every minute"
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
    web_links_run_json web_links_run_known web_links_run_ports web_links_run_ip web_links_run_http \
    web_links_run_entry web_links_run_list web_links_run_containers web_links_run_teamspeak web_links_run
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
    pihole|web|teamspeak|teamspeak-usage|samba) printf -- '-\n' ;;
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

# The Pi's LAN address: the source address of its default route (no packet
# is sent), else the first address "hostname -I" reports, else nothing.
web_links_run_ip() {
  local addr
  addr="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n1)" || addr=""
  [[ -n "$addr" ]] || addr="$(hostname -I 2>/dev/null | awk '{print $1}')" || addr=""
  printf '%s\n' "$addr"
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
  printf '{"host":%s,"ip":%s,"services":[\n' "$(web_links_run_json "$(hostname 2>/dev/null || true)")" \
    "$(web_links_run_json "$(web_links_run_ip)")"
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

# Print containers.json: every container, running or not, by name, with its
# image, state, health, restart count, network mode and the ports it
# publishes. Start and stop are timestamps (the page works out the uptime),
# so the file only changes when a container does.
web_links_run_containers() {
  local fmt name image state health started finished restarts net ports p host ip sep="" list
  printf '{"containers":[\n'
  if have docker && docker info >/dev/null 2>&1; then
    # Written for Docker's raw JSON (HostIp, a missing Health key), which
    # "docker inspect" falls back to when the template does not fit its types.
    fmt=$'{{.Name}}\x1f{{.Config.Image}}\x1f{{.State.Status}}\x1f{{with index .State "Health"}}{{index . "Status"}}{{end}}\x1f'
    fmt+=$'{{.State.StartedAt}}\x1f{{.State.FinishedAt}}\x1f{{.RestartCount}}\x1f{{.HostConfig.NetworkMode}}\x1f'
    # shellcheck disable=SC2016 # Go template variables, not shell ones.
    fmt+='{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}>{{$p}} {{end}}{{end}}'
    while IFS=$'\x1f' read -r name image state health started finished restarts net ports; do
      [[ -n "$name" ]] || continue
      [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
      # Ports as "8090:9393/tcp", once each (IPv4 and IPv6 bindings are the same
      # port), without those bound to localhost only.
      list=""
      for p in $ports; do
        host="${p%%>*}"
        ip="${host%:*}"
        [[ "$ip" != 127.* && "$ip" != ::1 ]] || continue
        p="$(web_links_run_json "${host##*:}:${p#*>}")"
        [[ ",$list," == *",$p,"* ]] || list+="${list:+,}$p"
      done
      # "2026-10-03T09:55:01.123456789Z" -> "2026-10-03T09:55:01Z"; Docker
      # reports year 1 for a time that never happened.
      started="${started%%.*}" finished="${finished%%.*}"
      started="${started%Z}" finished="${finished%Z}"
      [[ -n "$started" && "$started" != 0001-* ]] && started+=Z || started=""
      [[ -n "$finished" && "$finished" != 0001-* ]] && finished+=Z || finished=""
      printf '%s{"name":%s,"image":%s,"state":%s,"health":%s,"started":%s,"finished":%s,"restarts":%s,"network":%s,"ports":[%s]}' \
        "$sep" "$(web_links_run_json "${name#/}")" "$(web_links_run_json "$image")" \
        "$(web_links_run_json "$state")" "$(web_links_run_json "$health")" \
        "$(web_links_run_json "$started")" "$(web_links_run_json "$finished")" \
        "$((10#$restarts))" "$(web_links_run_json "$net")" "$list"
      sep=$',\n'
    done < <(docker ps -aq 2>/dev/null | xargs -r docker inspect -f "$fmt" 2>/dev/null | sort)
  fi
  printf '\n]}\n'
}

# Copy the TeamSpeak usage summary (teamspeak task, TEAMSPEAK_USAGE) to
# teamspeak.json next to $WL_OUT while its logger keeps it fresh (it rewrites
# it every minute), else remove it so the page hides the section.
web_links_run_teamspeak() {
  local src dest="${WL_OUT%/*}/teamspeak.json"
  src="$(container_dir teamspeak)/usage/data/usage.json"
  if [[ -f "$src" && -n "$(find "$src" -mmin -10 2>/dev/null)" ]]; then
    write_if_changed "$dest" 0644 <"$src" || true
  else
    rm -f "$dest"
  fi
}

# Write the lists to $WL_OUT, and containers.json and teamspeak.json next to
# it; each file only changes when its list does.
web_links_run() {
  web_links_run_list | write_if_changed "$WL_OUT" 0644 || true
  web_links_run_containers | write_if_changed "${WL_OUT%/*}/containers.json" 0644 || true
  web_links_run_teamspeak
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
  web_links_refresh
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
