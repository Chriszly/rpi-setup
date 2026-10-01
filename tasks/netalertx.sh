#!/usr/bin/env bash
# Task: netalertx - LAN device presence tracking via NetAlertX (Docker).
# Settings: NETALERTX_* in config/rpi-setup.env (names in config/tasks/netalertx.env).
set -euo pipefail

TASKS+=("netalertx|LAN device presence tracking (web UI :20211)")

run_netalertx() {
  : "${NETALERTX_PORT:=20211}" "${NETALERTX_IMAGE:=ghcr.io/netalertx/netalertx:latest}"
  : "${NETALERTX_LOGIN:=yes}"
  require_port NETALERTX_PORT
  local login=no
  setting_on NETALERTX_LOGIN && login=yes
  [[ "${NETALERTX_PASSWORD:-}" != *[[:cntrl:]]* ]] || die 'NETALERTX_PASSWORD must not contain control characters'
  require_image_ref NETALERTX_IMAGE
  local subnets="${NETALERTX_SCAN_SUBNETS:-}"
  if [[ -n "$subnets" ]]; then
    # e.g. "192.168.1.0/24 --interface=eth0"; several separated by ";".
    [[ "$subnets" =~ ^[0-9./]+\ --interface=[A-Za-z0-9._-]+(\;[0-9./]+\ --interface=[A-Za-z0-9._-]+)*$ ]] ||
      die "NETALERTX_SCAN_SUBNETS must look like '192.168.1.0/24 --interface=eth0' (got '$subnets')"
  fi
  require_docker

  local dir=/opt/netalertx
  local name=netalertx
  local ip=""

  local uid
  uid="$(assign_uid netalertx)"
  ensure_container_dir "$dir" "$uid"

  local subnet_cfg="" s list="" pw_hash=""
  local -a parts=()
  if [[ -n "$subnets" ]]; then
    subnet_cfg="$subnets"
    say "Scanning NETALERTX_SCAN_SUBNETS: $subnet_cfg"
  elif subnet_cfg="$(detect_subnet)"; then
    say "Detected LAN subnet: $subnet_cfg"
  else
    subnet_cfg=""
  fi
  if [[ -n "$subnet_cfg" ]]; then
    IFS=';' read -r -a parts <<<"$subnet_cfg"
    for s in "${parts[@]}"; do list+="${list:+,}'${s}'"; done
    list="[${list}]"
  else
    warn "Could not auto-detect LAN subnet; set SCAN_SUBNETS in the UI (Settings > Subnets & Rules)"
  fi
  if [[ $login == yes ]]; then
    netalertx_password
    pw_hash="$(netalertx_hash "$netalertx_pw")"
  fi
  # Applied by NetAlertX at container start (it survives restarts and needs no
  # post-start edit for the scanner). The login page itself reads app.conf, so
  # the SETPWD_* keys are also written there below (netalertx_apply_login).
  local conf_override
  conf_override="APP_CONF_OVERRIDE: $(netalertx_yaml_dq "$(netalertx_override_json "$list" "$login" "$pw_hash")")"

  # NetAlertX recommends arp_ignore=1 / arp_announce=2 to avoid ARP flux while
  # it scans. With network_mode: host the container shares the host's network
  # namespace, and runc refuses any net.* sysctl there ("not allowed in host
  # network namespace"), so they must be applied on the host instead.
  cat >/etc/sysctl.d/90-netalertx.conf <<'EOF'
# Managed by rpi-setup (tasks/netalertx.sh): ARP flux mitigation for NetAlertX.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF
  sysctl -q -p /etc/sysctl.d/90-netalertx.conf || warn 'Could not apply /etc/sysctl.d/90-netalertx.conf (applied on next boot)'

  local changed=0
  if write_if_changed "$dir/docker-compose.yml" 0600 <<EOF
services:
  netalertx:
    image: "$NETALERTX_IMAGE"
    container_name: $name
    network_mode: host
    read_only: true
    restart: unless-stopped
    pids_limit: 512
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,noexec,nosuid,nodev,async,noatime,nodiratime"
    environment:
      PUID: $uid
      PGID: $uid
      LISTEN_ADDR: 0.0.0.0
      PORT: $NETALERTX_PORT
      $conf_override
    volumes:
      - type: bind
        source: $dir/data
        target: /data
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
EOF
  then
    changed=1
  fi

  if [[ $changed -eq 0 ]] && compose_is_up "$name"; then
    netalertx_apply_login "$dir/data/config/app.conf" "$login" "$pw_hash"
    ip="$(pi_ip)" || true
    say "NetAlertX is already running with these settings. Dashboard: http://${ip:-<pi-ip>}:${NETALERTX_PORT}"
    return
  fi

  # 'up -d' recreates the container when the compose file changed, so a new
  # password, login or subnet setting takes effect; otherwise it just starts it.
  say 'Starting NetAlertX container'
  compose_up "$dir"
  netalertx_apply_login "$dir/data/config/app.conf" "$login" "$pw_hash"

  ip="$(pi_ip)" || true
  say "NetAlertX dashboard: http://${ip:-<pi-ip>}:${NETALERTX_PORT}"
  say "Give it a few minutes to run its first ARP scan. Initial discovery can take 5-10 minutes."
}

# --- netalertx helpers (unit tested in ci/test-task-netalertx.sh) ------------

netalertx_secret_file=/var/lib/rpi-setup/secrets/netalertx.env

# Print $1 as a JSON string literal (quotes, backslashes, control chars escaped).
netalertx_json_str() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      '"') out+='\"' ;;
      \\) out+="\\\\" ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      [[:cntrl:]]) printf -v c '\\u%04x' "'$c"; out+="$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '"%s"' "$out"
}

# Print $1 as a YAML double-quoted scalar.
netalertx_yaml_dq() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# The APP_CONF_OVERRIDE JSON: SCAN_SUBNETS (Python list literal $1, left out
# when empty) and the SETPWD_* login keys ($2 yes/no, $3 = SHA-256 hex).
netalertx_override_json() {
  local subnets="$1" login="$2" hash="$3" json=""
  [[ -z "$subnets" ]] || json+="\"SCAN_SUBNETS\":$(netalertx_json_str "$subnets")"
  if [[ "$login" == yes ]]; then
    json+="${json:+,}\"SETPWD_enable_password\":\"True\",\"SETPWD_password\":$(netalertx_json_str "$hash")"
  else
    json+="${json:+,}\"SETPWD_enable_password\":\"False\""
  fi
  printf '{%s}' "$json"
}

# NetAlertX stores the web UI password as its unsalted SHA-256 hex digest.
netalertx_hash() {
  local h
  h="$(printf '%s' "$1" | sha256sum)"
  printf '%s\n' "${h%% *}"
}

# The password generated on an earlier run, if any.
netalertx_saved_password() {
  local line
  [[ -r "$netalertx_secret_file" ]] || return 1
  line="$(grep -m1 '^NETALERTX_PASSWORD=' "$netalertx_secret_file")" || return 1
  line="${line#NETALERTX_PASSWORD=}"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# Set netalertx_pw: NETALERTX_PASSWORD, else the saved one, else a new one
# (printed once and saved, so re-runs keep the same password).
netalertx_password() {
  if [[ -n "${NETALERTX_PASSWORD:-}" ]]; then
    netalertx_pw="$NETALERTX_PASSWORD"
  elif netalertx_pw="$(netalertx_saved_password)"; then
    info "Web UI login: using the password saved in $netalertx_secret_file"
  else
    netalertx_pw="$(gen_secret 20)"
    save_secret netalertx NETALERTX_PASSWORD "$netalertx_pw"
    say "Generated NetAlertX web UI password: $netalertx_pw"
    info "Saved in $netalertx_secret_file; set NETALERTX_PASSWORD to choose your own."
  fi
}

# Set KEY=VALUE in app.conf (replace the first KEY= line, drop duplicates,
# append if missing). Keeps the file's owner and mode. False if unchanged.
netalertx_conf_set() {
  local file="$1" key="$2" value="$3"
  awk -v key="$key" -v line="$key=$value" '
    $0 ~ ("^" key "[ \t]*=") { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }' "$file" | write_if_changed "$file"
}

# The login page reads SETPWD_* straight from app.conf (APP_CONF_OVERRIDE only
# reaches the backend), so write them there too. NetAlertX re-reads the file
# when it changes, so no restart is needed. On a first install the container
# creates app.conf, so wait for it.
netalertx_apply_login() {
  local conf="$1" login="$2" hash="$3" i
  if [[ ! -f "$conf" ]]; then
    for ((i = 0; i < 90; i++)); do
      sleep 1
      [[ -f "$conf" ]] && break
    done
    if [[ ! -f "$conf" ]]; then
      [[ "$login" == yes ]] || return 0
      die "NetAlertX did not create $conf, so the web UI login is NOT on yet. Check 'docker logs netalertx', then re-run: sudo bash setup.sh netalertx"
    fi
    sleep 2 # let the entrypoint finish its first-run edits of app.conf
  fi
  if [[ "$login" == yes ]]; then
    # Password first, so the login never switches on with an old password.
    netalertx_conf_set "$conf" SETPWD_password "'$hash'" || true
    netalertx_conf_set "$conf" SETPWD_enable_password True || true
    say 'NetAlertX web UI login is on (password: NETALERTX_PASSWORD or the saved one)'
  else
    netalertx_conf_set "$conf" SETPWD_enable_password False || true
    warn 'NetAlertX web UI login is off (NETALERTX_LOGIN=no): anyone on the LAN can open it'
  fi
}
