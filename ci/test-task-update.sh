#!/usr/bin/env bash
# test-task-update.sh - tests for update.sh: which steps it picks, what
# --dry-run prints, and that one failing step does not stop the others.
#
# apt-get, docker, pihole and rpi-eeprom-update are PATH shims in a temp dir
# that only log their arguments; PATH holds nothing else (the few tools
# update.sh needs are symlinked in), so a real Docker or Pi-hole on the test
# machine is never touched. The non-dry-run cases need root (update.sh checks).
#
# Run: bash ci/test-task-update.sh   (sudo bash ci/test-task-update.sh for all cases)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
BASH_BIN="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/calls.log"

# Base tools update.sh and lib/common.sh use, linked into a dir of their own.
mkdir -p "$TMP/base"
for t in bash basename dirname tr cat grep sed; do
    if p="$(command -v "$t")"; then ln -sf "$p" "$TMP/base/$t"; fi
done

# make_shims DIR CMD... - a logging stub per CMD. A stub exits 1 when its
# command line contains $SHIM_FAIL (e.g. "netalertx/docker-compose.yml pull").
make_shims() {
    local dir="$1" c; shift
    mkdir -p "$dir"
    for c in "$@"; do
        cat >"$dir/$c" <<SH
#!$BASH_BIN
printf '%s %s\n' "$c" "\$*" >>"\$LOG"
[[ -n "\${SHIM_FAIL:-}" && "$c \$*" == *"\$SHIM_FAIL"* ]] && exit 1
exit 0
SH
        chmod +x "$dir/$c"
    done
}
make_shims "$TMP/all" apt-get docker pihole rpi-eeprom-update
make_shims "$TMP/nodocker" apt-get pihole rpi-eeprom-update

# Fake /opt: two rpi-setup projects, one foreign project, one dir without compose.
OPT="$TMP/opt"
mkdir -p "$OPT/netalertx" "$OPT/teamspeak" "$OPT/other" "$OPT/samba"
touch "$OPT/netalertx/docker-compose.yml" "$OPT/teamspeak/docker-compose.yml" "$OPT/other/docker-compose.yml"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$TMP/model-pi"
printf 'Generic x86 PC\0' >"$TMP/model-pc"

# upd SHIMDIR MODEL ARGS... - run update.sh in a clean environment; sets
# $OUT (stdout and stderr) and $RC (exit code).
upd() {
    local shims="$1" model="$2"; shift 2
    : >"$LOG"
    RC=0
    OUT="$(env -i PATH="$TMP/$shims:$TMP/base" LOG="$LOG" SHIM_FAIL="${SHIM_FAIL:-}" \
        RPI_SETUP_OPT_DIR="$OPT" RPI_SETUP_MODEL_FILE="$TMP/model-$model" \
        RPI_SETUP_REBOOT_FILE="$TMP/reboot-required" \
        "$BASH_BIN" "$ROOT/update.sh" "$@" 2>&1)" || RC=$?
}

# assert_lacks NAME NEEDLE HAYSTACK
assert_lacks() {
    if [[ "$3" == *"$2"* ]]; then fail "$1 (did not expect '$2')"; else pass "$1"; fi
}

# --- Options ---------------------------------------------------------------
upd all pi --help
assert_eq "--help exits 0" 0 "$RC"
assert_contains "--help shows usage" "Usage: sudo bash update.sh" "$OUT"
upd all pi --bogus
assert_eq "unknown option exits non-zero" 1 "$RC"
assert_contains "unknown option is named" "unknown option: --bogus" "$OUT"

# --- Dry run: every step on a Pi with everything installed -------------------
upd all pi --dry-run
assert_eq "dry-run exits 0" 0 "$RC"
assert_eq "dry-run runs nothing" "" "$(cat "$LOG")"
assert_contains "dry-run: apt update" "[dry-run] apt-get update -y" "$OUT"
assert_contains "dry-run: apt upgrade with the noninteractive dpkg options" \
    "[dry-run] apt-get upgrade -y --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold" "$OUT"
assert_contains "dry-run: pull netalertx" "[dry-run] docker compose -f $OPT/netalertx/docker-compose.yml pull" "$OUT"
assert_contains "dry-run: up netalertx" "[dry-run] docker compose -f $OPT/netalertx/docker-compose.yml up -d" "$OUT"
assert_contains "dry-run: pull teamspeak" "[dry-run] docker compose -f $OPT/teamspeak/docker-compose.yml pull" "$OUT"
assert_contains "dry-run: up teamspeak" "[dry-run] docker compose -f $OPT/teamspeak/docker-compose.yml up -d" "$OUT"
assert_contains "dry-run: image prune" "[dry-run] docker image prune -f" "$OUT"
assert_contains "dry-run: pihole -up" "[dry-run] pihole -up" "$OUT"
assert_contains "dry-run: eeprom" "[dry-run] rpi-eeprom-update -a" "$OUT"
assert_lacks "a compose project not written by rpi-setup is left alone" "$OPT/other" "$OUT"
assert_lacks "no reboot hint without reboot-required" "Reboot recommended" "$OUT"

# --- Step selection ----------------------------------------------------------
upd all pi --dry-run --no-apt --no-containers
assert_eq "--no-apt --no-containers exits 0" 0 "$RC"
assert_lacks "--no-apt skips apt" "[dry-run] apt-get" "$OUT"
assert_lacks "--no-containers skips docker" "[dry-run] docker" "$OUT"
assert_contains "--no-apt is reported" "skipped (--no-apt)" "$OUT"
assert_contains "--no-containers is reported" "skipped (--no-containers)" "$OUT"
assert_contains "Pi-hole still updates" "[dry-run] pihole -up" "$OUT"

upd nodocker pc --dry-run
assert_eq "dry-run without docker exits 0" 0 "$RC"
assert_contains "no docker: containers skipped" "skipped (Docker not installed)" "$OUT"
assert_contains "not a Pi: eeprom skipped" "skipped (not a Raspberry Pi)" "$OUT"
assert_lacks "not a Pi: eeprom not run" "[dry-run] rpi-eeprom-update" "$OUT"

upd "base" pi --dry-run
assert_contains "no pihole: skipped" "skipped (Pi-hole not installed)" "$OUT"
assert_contains "no apt-get: skipped" "skipped (apt-get not found)" "$OUT"
assert_contains "no rpi-eeprom-update: skipped" "skipped (rpi-eeprom-update not found)" "$OUT"

rm -f "$OPT/netalertx/docker-compose.yml" "$OPT/teamspeak/docker-compose.yml"
upd all pi --dry-run
assert_contains "no rpi-setup project: containers skipped" "skipped (no rpi-setup compose project" "$OUT"
touch "$OPT/netalertx/docker-compose.yml" "$OPT/teamspeak/docker-compose.yml"

touch "$TMP/reboot-required"
upd all pi --dry-run --no-apt
assert_contains "reboot-required gives a reboot hint" "Reboot recommended" "$OUT"
rm -f "$TMP/reboot-required"

# --- Real runs against the shims (update.sh needs root) ---------------------
if [[ $EUID -eq 0 ]]; then
    upd all pi
    assert_eq "full run exits 0" 0 "$RC"
    expected="apt-get update -y
apt-get upgrade -y --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
docker compose -f $OPT/netalertx/docker-compose.yml pull
docker compose -f $OPT/netalertx/docker-compose.yml up -d
docker compose -f $OPT/teamspeak/docker-compose.yml pull
docker compose -f $OPT/teamspeak/docker-compose.yml up -d
docker image prune -f
pihole -up
rpi-eeprom-update -a"
    assert_eq "full run calls every step in order" "$expected" "$(cat "$LOG")"

    SHIM_FAIL="netalertx/docker-compose.yml pull" upd all pi --no-apt
    assert_eq "a failed pull makes the run fail" 1 "$RC"
    assert_contains "the failed step is in the summary" "containers  failed" "$OUT"
    assert_contains "other projects still update after a failure" \
        "docker compose -f $OPT/teamspeak/docker-compose.yml up -d" "$(cat "$LOG")"
    assert_contains "later steps still run after a failure" "pihole -up" "$(cat "$LOG")"
    assert_lacks "a project whose pull failed is not restarted" \
        "netalertx/docker-compose.yml up -d" "$(cat "$LOG")"

    SHIM_FAIL="apt-get update" upd all pi
    assert_eq "a failed apt update makes the run fail" 1 "$RC"
    assert_lacks "no upgrade after a failed apt update" "apt-get upgrade" "$(cat "$LOG")"
    assert_contains "containers still update after apt failed" "docker image prune -f" "$(cat "$LOG")"
else
    skip "real runs against the shims need root"
fi

finish_tests
