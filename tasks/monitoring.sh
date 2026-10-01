#!/usr/bin/env bash
# Task: monitoring - Netdata for real-time system dashboards.
set -euo pipefail

TASKS+=("monitoring|Netdata monitoring dashboard (web UI :19999)")

run_monitoring() {
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
  # be unreachable from other machines. Open it to the LAN (idempotent).
  local conf=/etc/netdata/netdata.conf changed=0
  if netdata_listen_on_lan "$conf"; then
    changed=1
    info "Netdata now listens on all interfaces ($conf)"
  fi

  systemctl enable --now netdata
  if [[ $changed -eq 1 ]]; then
    systemctl restart netdata
  fi

  local ip=""
  ip="$(pi_ip)" || true
  say "Netdata dashboard: http://${ip:-$(hostname)}:19999"
}

# Rewrite a localhost-only bind in netdata.conf to 0.0.0.0. Returns 0 if the
# file was changed, 1 if there was nothing to change.
netdata_listen_on_lan() {
  local conf="$1"
  local re='^([[:space:]]*(bind socket to IP|bind to)[[:space:]]*=[[:space:]]*)(127\.0\.0\.1|localhost)[[:space:]]*$'
  if [[ ! -f "$conf" ]] || ! grep -Eq "$re" "$conf"; then return 1; fi
  sed -Ei "s/$re/\\10.0.0.0/" "$conf"
}

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
