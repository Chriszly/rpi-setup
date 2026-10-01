#!/usr/bin/env bash
# Task: monitoring - Netdata for real-time system dashboards.
# Settings: MONITORING_* in config/rpi-setup.env (names in config/tasks/monitoring.env).
set -euo pipefail

TASKS+=("monitoring|Netdata monitoring dashboard (web UI :19999)")

run_monitoring() {
  : "${MONITORING_PORT:=19999}" "${MONITORING_BIND:=0.0.0.0}" "${MONITORING_TELEMETRY:=no}"
  require_port MONITORING_PORT
  [[ "$MONITORING_BIND" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}|localhost|\*)$ ]] ||
    die "MONITORING_BIND must be an IPv4 address such as 0.0.0.0 (all) or 127.0.0.1 (got '$MONITORING_BIND')"
  setting_on MONITORING_TELEMETRY || true

  # Netdata's documented opt-out of anonymous usage statistics. Written
  # before the install, so a fresh Netdata never reports and needs no restart.
  local optout=/etc/netdata/.opt-out-from-anonymous-statistics changed=0
  if setting_on MONITORING_TELEMETRY; then
    if [[ -e "$optout" ]]; then rm -f "$optout"; changed=1; fi
  elif [[ ! -e "$optout" ]]; then
    install -m 0755 -d /etc/netdata
    touch "$optout"
    if apt_installed netdata; then changed=1; fi
  fi

  if ! apt_installed netdata; then
    apt_update
    if ! apt_has_candidate netdata; then
      # Debian 13 (Trixie, today's Raspberry Pi OS) no longer ships netdata;
      # use Netdata's own apt repository, as its official installer does.
      add_netdata_repo
    fi
    apt_install netdata
  fi

  # Debian's netdata package only listens on 127.0.0.1, so the dashboard would
  # be unreachable from other machines. Bind where MONITORING_BIND says
  # (default: all interfaces) and on MONITORING_PORT (idempotent).
  local conf=/etc/netdata/netdata.conf
  if netdata_set_bind "$conf" "$MONITORING_BIND"; then
    changed=1
    info "Netdata now listens on $MONITORING_BIND ($conf)"
  fi
  if netdata_set_port "$conf" "$MONITORING_PORT"; then
    changed=1
    info "Netdata now listens on port $MONITORING_PORT ($conf)"
  fi

  systemctl enable --now netdata
  if [[ $changed -eq 1 ]]; then
    systemctl restart netdata
  fi

  local ip=""
  ip="$(pi_ip)" || true
  if [[ "$MONITORING_BIND" == 127.0.0.1 || "$MONITORING_BIND" == localhost ]]; then
    say "Netdata dashboard (this Pi only): http://localhost:${MONITORING_PORT}"
  else
    say "Netdata dashboard: http://${ip:-$(hostname)}:${MONITORING_PORT}"
  fi
}

# Point every "bind socket to IP" / "bind to" line of netdata.conf at $2, or
# add "bind to" under [web] when there is none and $2 is not the default
# (all interfaces). Returns 0 if the file was changed.
netdata_set_bind() {
  local conf="$1" ip="$2"
  local re='^([[:space:]]*(bind socket to IP|bind to)[[:space:]]*=[[:space:]]*)(.*[^[:space:]])[[:space:]]*$'
  if [[ -f "$conf" ]] && grep -Eq "$re" "$conf"; then
    # Nothing to do when every bind line already says $ip.
    grep -E "$re" "$conf" | sed -E "s/$re/\\3/" | grep -qvxF "$ip" || return 1
    sed -Ei "s/$re/\\1$ip/" "$conf"
    return 0
  fi
  [[ "$ip" != 0.0.0.0 && "$ip" != '*' ]] || return 1
  ini_set "$conf" web 'bind to' "$ip"
}

# Set [web] "default port" in netdata.conf, unless it is already $2 (19999,
# Netdata's default, needs no line). Returns 0 if the file was changed.
netdata_set_port() {
  local conf="$1" port="$2" cur
  cur="$(sed -nE 's/^[[:space:]]*default port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$conf" 2>/dev/null | head -n1)"
  [[ "${cur:-19999}" != "$port" ]] || return 1
  ini_set "$conf" web 'default port' "$port"
}

# Rewrite a localhost-only bind in netdata.conf to 0.0.0.0. Returns 0 if the
# file was changed, 1 if there was nothing to change.
netdata_listen_on_lan() { netdata_set_bind "$1" 0.0.0.0; }

# True if apt can install package $1 from a configured source.
apt_has_candidate() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Add Netdata's signed stable apt repository for this OS release.
add_netdata_repo() {
  local codename
  codename=$( . /etc/os-release && echo "${VERSION_CODENAME:-}" ) || true
  [[ -n "$codename" ]] || die 'Could not determine the OS release (VERSION_CODENAME) for the Netdata repository.'
  info "netdata is not in the ${codename} archive; adding Netdata's apt repository"
  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://repo.netdata.cloud/netdatabot.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/netdata.gpg
  chmod a+r /etc/apt/keyrings/netdata.gpg
  echo "deb [signed-by=/etc/apt/keyrings/netdata.gpg] https://repository.netdata.cloud/repos/stable/debian/ ${codename}/" \
    >/etc/apt/sources.list.d/netdata.list
  apt_update_now
  apt_has_candidate netdata || die "Netdata publishes no package for '${codename}' on this architecture; skip the monitoring task."
}
