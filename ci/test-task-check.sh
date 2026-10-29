#!/usr/bin/env bash
# test-task-check.sh - unit tests for check.sh (the read-only health check):
# the throttling decoder, the thresholds and the output format. Sourcing
# check.sh defines its functions without running main().
#
# Run: bash ci/test-task-check.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/check.sh"

# --- throttle_status ----------------------------------------------------------
assert_eq "throttle 0x0 is OK" "OK|0x0 (no under-voltage or throttling)" "$(throttle_status throttled=0x0)"
assert_eq "throttle accepts a bare value" "OK" "$(throttle_status 0x0 | cut -d'|' -f1)"

t="$(throttle_status throttled=0x50005)"
assert_eq "throttle 0x50005 (under-voltage now) is FAIL" "FAIL" "${t%%|*}"
assert_contains "throttle 0x50005 names under-voltage now" "under-voltage now" "$t"
assert_contains "throttle 0x50005 names throttled now" "throttled now" "$t"
assert_contains "throttle 0x50005 names under-voltage since boot" "under-voltage since boot" "$t"
assert_contains "throttle 0x50005 names throttling since boot" "throttled since boot" "$t"
assert_contains "throttle under-voltage points at the power supply" "power supply" "$t"

t="$(throttle_status throttled=0x50000)"
assert_eq "throttle 0x50000 (only since boot) is WARN" "WARN" "${t%%|*}"
assert_contains "throttle 0x50000 lists both flags" "under-voltage since boot, throttled since boot" "$t"

t="$(throttle_status throttled=0x80008)"
assert_eq "throttle 0x80008 (soft temp limit now) is WARN" "WARN" "${t%%|*}"
assert_contains "throttle 0x80008 names the soft limit" "soft temperature limit now" "$t"
assert_lacks "temperature-only throttling does not blame the power supply" "power supply" "$t"

t="$(throttle_status throttled=0x4)"
assert_eq "throttle 0x4 (throttled now) is FAIL" "FAIL" "${t%%|*}"
t="$(throttle_status throttled=0x20002)"
assert_eq "throttle 0x20002 (capped now and since boot) is WARN" "WARN" "${t%%|*}"
assert_contains "throttle 0x20002 names the capping" "CPU frequency capped now, frequency capped since boot" "$t"

assert_eq "throttle garbage is WARN" "WARN" "$(throttle_status 'VCHI initialization failed' | cut -d'|' -f1)"
assert_eq "throttle empty is WARN" "WARN" "$(throttle_status '' | cut -d'|' -f1)"

# --- temp_status / disk_status / http_status ------------------------------------
assert_eq "temp 45.0 C is OK"   OK   "$(temp_status 45000)"
assert_eq "temp 69.9 C is OK"   OK   "$(temp_status 69999)"
assert_eq "temp 70.0 C is WARN" WARN "$(temp_status 70000)"
assert_eq "temp 80.0 C is FAIL" FAIL "$(temp_status 80000)"
assert_eq "temp garbage is WARN" WARN "$(temp_status abc)"

assert_eq "disk 12% is OK"   OK   "$(disk_status 12%)"
assert_eq "disk 79% is OK"   OK   "$(disk_status 79)"
assert_eq "disk 80% is WARN" WARN "$(disk_status 80%)"
assert_eq "disk 95% is FAIL" FAIL "$(disk_status 95%)"
assert_eq "disk garbage is WARN" WARN "$(disk_status -)"

assert_eq "http 200 is OK"   OK   "$(http_status 200)"
assert_eq "http 302 is OK"   OK   "$(http_status 302)"
assert_eq "http 404 is WARN" WARN "$(http_status 404)"
assert_eq "http 000 is FAIL" FAIL "$(http_status 000)"
assert_eq "http empty is FAIL" FAIL "$(http_status '')"
assert_eq "http 401 with any is OK" OK "$(http_status 401 any)"
assert_eq "http 000 with any is FAIL" FAIL "$(http_status 000 any)"

# --- port_setting ---------------------------------------------------------------
assert_eq "port_setting uses the default when unset" 20211 "$(unset NETALERTX_PORT; port_setting NETALERTX_PORT 20211)"
assert_eq "port_setting uses a valid value" 20000 "$(NETALERTX_PORT=20000 port_setting NETALERTX_PORT 20211)"
assert_eq "port_setting ignores an invalid value" 20211 "$(NETALERTX_PORT=99999 port_setting NETALERTX_PORT 20211)"
assert_eq "port_setting ignores text" 20211 "$(NETALERTX_PORT=abc port_setting NETALERTX_PORT 20211)"

# --- report / summary -----------------------------------------------------------
out="$(report OK ssh "service ssh active, enabled")"
assert_eq "report pads status and name" "OK    ssh                    service ssh active, enabled" "$out"
out="$(report FAIL "pihole: admin" "http://x/admin/ not reachable")"
assert_eq "report FAIL line" "FAIL  pihole: admin          http://x/admin/ not reachable" "$out"
assert_fails "report rejects an unknown status" report MAYBE x y

out="$(
  report OK a 1 >/dev/null
  report WARN b 2 >/dev/null
  report OK c 3 >/dev/null
  summary
)"
assert_eq "summary counts OK and WARN" "Summary: 2 OK, 1 WARN, 0 FAIL" "$out"
assert_ok "summary exits 0 without FAIL" bash -c ". '$ROOT/check.sh'; report WARN a b >/dev/null; summary >/dev/null"
assert_fails "summary exits 1 with a FAIL" bash -c ". '$ROOT/check.sh'; report FAIL a b >/dev/null; summary >/dev/null"

# --- check_service (systemctl stubbed) --------------------------------------------
systemctl() {
  case "$1 $2" in
    "is-active up")   echo active ;;
    "is-enabled up")  echo enabled ;;
    "is-active half") echo active ;;
    "is-enabled half") echo disabled; return 1 ;;
    "is-active down") echo failed; return 3 ;;
    "is-enabled down") echo enabled ;;
  esac
}
assert_eq "check_service active+enabled is OK" "OK" "$(check_service up | cut -c1-4 | tr -d ' ')"
assert_contains "check_service active+disabled warns about reboot" "will not start after reboot" "$(check_service half)"
assert_eq "check_service failed is FAIL" "FAIL" "$(check_service down | cut -c1-4 | tr -d ' ')"
unset -f systemctl

# --- check_tasks in container mode (<TASK>_DOCKER=yes, docker stubbed) ----------
ctr="$(mktemp -d)"
for t in web pihole samba; do install -d "$ctr/$t"; touch "$ctr/$t/docker-compose.yml"; done
install -d "$ctr/web/conf" "$ctr/samba/data"
printf 'server {\n    listen 8088;\n}\n' >"$ctr/web/conf/default.conf"
printf 'share:\n  - name: "nas-share"\n' >"$ctr/samba/data/config.yml"
# The stubs live in the subshell, so the library's own helpers stay intact.
out="$(
  docker() {
    case "$1 ${2:-}" in
      "inspect --type") [[ " web pihole samba " == *" ${4:-} "* ]] ;;
      "inspect -f") echo running ;;
      "exec pihole") echo '8089o,[::]:8089o' ;;
      *) return 1 ;;
    esac
  }
  curl() { printf '200'; }
  ss() { echo 'LISTEN 0 0 *:x *:*'; }
  unit_exists() { return 1; }
  apt_installed() { return 1; }
  RPI_SETUP_CONTAINER_ROOT="$ctr" RPI_SETUP_CONFIG_DIR="$ctr/cfg" check_tasks 2>&1
)"
for c in web pihole samba; do
  assert_contains "container mode: $c is checked as a container" "container $c" "$out"
done
assert_contains "container mode: web port from the container's site" ":8088/" "$out"
assert_contains "container mode: Pi-hole port from FTL in the container" ":8089/admin/" "$out"
assert_contains "container mode: samba share from config.yml" "[nas-share] in the container's config.yml" "$out"
assert_lacks "container mode: no native nginx check" "service nginx" "$out"
assert_lacks "container mode: no native smbd check" "service smbd" "$out"
rm -rf "$ctr"

# --- check_tasks: firewall, backup, runner, web timers, netalertx, teamspeak -----
# systemctl, nft and docker are stubbed; the units and projects "exist" in a
# temp folder. The firewall unit is active while the nft table is missing.
ctr="$(mktemp -d)"
for t in netalertx teamspeak; do install -d "$ctr/$t"; touch "$ctr/$t/docker-compose.yml"; done
install -d "$ctr/runner" "$ctr/cfg/local"
printf 'actions.runner.alex-pis.homepi.service\n' >"$ctr/runner/.service"
printf "TEAMSPEAK_QUERY_HTTP='yse'\n" >"$ctr/cfg/local/teamspeak.env"
chmod 0600 "$ctr/cfg/local/teamspeak.env"
# stubs UNITS... - the stubs for one check_tasks run: the named systemd units
# exist (unit_exists goes through systemctl list-unit-files), every unit is
# active and enabled, the last backup run failed, nft returns $NFT_RC.
stubs() {
  STUB_UNITS=" $* "
  systemctl() {
    case "$1" in
      list-unit-files) [[ "$STUB_UNITS" == *" $3 "* ]] && echo "$3 enabled"; return 0 ;;
      is-active) echo active ;;
      is-enabled) echo enabled ;;
      is-failed) echo failed ;;
    esac
  }
  nft() { return "${NFT_RC:-1}"; }
  docker() { case "$1 ${2:-}" in "inspect -f") echo running ;; *) return 1 ;; esac; }
  curl() { printf '200'; }
  ss() { echo 'LISTEN 0 0 *:x *:*'; }
  apt_installed() { return 1; }
  have() { case "$1" in docker|nft|curl|ss|systemctl) return 0 ;; *) return 1 ;; esac; }
}
out="$(
  stubs rpi-setup-firewall.service rpi-setup-backup.timer actions.runner.alex-pis.homepi.service
  RPI_SETUP_CONTAINER_ROOT="$ctr" RPI_SETUP_CONFIG_DIR="$ctr/cfg" RPI_SETUP_RUNNER_DIR="$ctr/runner" check_tasks 2>&1
)"
assert_contains "firewall unit is checked" "OK    firewall               service rpi-setup-firewall active, enabled" "$out"
if [[ $EUID -eq 0 ]]; then
  assert_contains "a missing rpi_setup table is a FAIL although the unit is active" "FAIL  firewall: rules        table inet rpi_setup is missing" "$out"
else
  assert_contains "the rules are not read without root" "WARN  firewall: rules        not run as root" "$out"
fi
assert_contains "backup timer is checked" "OK    backup: timer          service rpi-setup-backup.timer active, enabled" "$out"
assert_contains "a failed backup run is a WARN" "WARN  backup: last run       failed" "$out"
assert_contains "runner service is checked by the unit svc.sh recorded" "OK    runner                 service actions.runner.alex-pis.homepi.service active" "$out"
assert_contains "netalertx is found under RPI_SETUP_CONTAINER_ROOT" "container netalertx" "$out"
assert_contains "teamspeak is found under RPI_SETUP_CONTAINER_ROOT" "container teamspeak" "$out"
assert_contains "a mistyped TEAMSPEAK_QUERY_HTTP is a WARN" "WARN  teamspeak: query       TEAMSPEAK_QUERY_HTTP must be yes or no (got 'yse')" "$out"
assert_lacks "web timers are only checked with the web task" "web: links timer" "$out"
out="$(
  NFT_RC=0
  stubs rpi-setup-firewall.service nginx.service rpi-setup-web-links.timer rpi-setup-updates.timer
  RPI_SETUP_CONTAINER_ROOT="$ctr/none" RPI_SETUP_CONFIG_DIR="$ctr/cfg" RPI_SETUP_RUNNER_DIR="$ctr/none" check_tasks 2>&1
)"
if [[ $EUID -eq 0 ]]; then
  assert_contains "a loaded rpi_setup table is OK" "OK    firewall: rules        table inet rpi_setup is loaded" "$out"
fi
assert_contains "web links timer is checked" "OK    web: links timer       service rpi-setup-web-links.timer active" "$out"
assert_contains "web updates timer is checked" "OK    web: updates timer     service rpi-setup-updates.timer active" "$out"
assert_lacks "no backup timer: nothing reported" "backup:" "$out"
assert_lacks "no runner: nothing reported" "runner" "$out"
unset -f stubs
rm -rf "$ctr"

# --- whole script ---------------------------------------------------------------
# Runs on any machine (CI runner, container): it may report FAILs there, but
# it must finish with a summary and exit 0 or 1, and must not print secrets.
cfg="$TMP/cfg"
install -d "$cfg/local"
printf "SAMBA_PASSWORD='citest-secret-%s'\n" "$$" >"$cfg/local/samba.env"
printf "TEAMSPEAK_QUERY_ADMIN_PASSWORD='citest-secret-%s'\n" "$$" >"$cfg/local/teamspeak.env"
chmod 0600 "$cfg"/local/*.env
rc=0
out="$(RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/check.sh" 2>&1)" || rc=$?
if [[ $rc -eq 0 || $rc -eq 1 ]]; then pass "check.sh exits 0 or 1 (got $rc)"; else fail "check.sh exited $rc"; printf '%s\n' "$out" >&2; fi
assert_contains "check.sh prints a summary line" "Summary: " "$(tail -n1 <<<"$out")"
assert_lacks "check.sh prints no secret" "citest-secret" "$out"
bad="$(grep -vE '^(OK|WARN|FAIL) |^Summary: |^rpi-setup health check - ' <<<"$out" || true)"
assert_eq "every check.sh line is a check, the header or the summary" "" "$bad"
assert_contains "check.sh --help shows usage" "sudo bash check.sh" "$(bash "$ROOT/check.sh" --help)"
assert_fails "check.sh rejects an unknown option" bash "$ROOT/check.sh" --bogus

finish_tests
