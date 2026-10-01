#!/usr/bin/env bash
# test-task-netalertx.sh - unit tests for the helpers in tasks/netalertx.sh:
# the APP_CONF_OVERRIDE JSON (and its YAML quoting), the app.conf edits and
# the web UI password reuse. The password cases touch
# /var/lib/rpi-setup/secrets/netalertx.env and only run as root; they restore
# any existing file afterwards.
#
# Run: bash ci/test-task-netalertx.sh   (sudo for the root-only cases)
# Many cases pass literal $ and \ strings on purpose.
# shellcheck disable=SC2016
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/netalertx.sh"

have_python=0
command -v python3 >/dev/null 2>&1 && have_python=1

# json_roundtrip JSON: print the decoded string (python3), or "INVALID".
json_roundtrip() {
    printf '%s' "$1" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.loads(sys.stdin.read()))
except Exception:
    sys.stdout.write("INVALID")'
}

# json_get JSON KEY: print the value of KEY in a JSON object, "MISSING" or "INVALID".
json_get() {
    printf '%s' "$1" | KEY="$2" python3 -c 'import json,os,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.stdout.write("INVALID"); sys.exit()
sys.stdout.write(str(d.get(os.environ["KEY"], "MISSING")))'
}

# --- netalertx_json_str ----------------------------------------------------------
assert_eq "json_str plain" '"abc"' "$(netalertx_json_str abc)"
assert_eq "json_str escapes quote and backslash" '"a\"b\\c"' "$(netalertx_json_str 'a"b\c')"
assert_eq "json_str escapes newline and tab" '"a\nb\tc"' "$(netalertx_json_str $'a\nb\tc')"
assert_eq "json_str escapes other control chars" '"a\u0001b"' "$(netalertx_json_str $'a\001b')"
assert_eq "json_str keeps single quotes" "\"['x']\"" "$(netalertx_json_str "['x']")"
assert_eq "json_str empty" '""' "$(netalertx_json_str '')"

if [[ $have_python -eq 1 ]]; then
    for odd in 'plain' 'q"uote' 'back\slash' "tr\\\\ail\\" $'multi\nline\r\t' $'bell\a esc\033' "sin'gle" 'ümläut €' '{"json":[1]}' '$HOME `id` $(id)'; do
        assert_eq "json_str round-trips: $(printf '%q' "$odd")" "$odd" "$(json_roundtrip "$(netalertx_json_str "$odd")")"
    done
else
    skip "json_str round-trip tests (python3 missing)"
fi

# --- netalertx_hash ----------------------------------------------------------------
# NetAlertX's default password 123456 is stored as this digest (docs/SECURITY.md).
assert_eq "hash is SHA-256 hex" "8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92" "$(netalertx_hash 123456)"
assert_eq "hash of odd password" "$(printf '%s' 'p"a\ss $x' | sha256sum | cut -d' ' -f1)" "$(netalertx_hash 'p"a\ss $x')"

# --- netalertx_override_json ------------------------------------------------------
subnets="['192.168.1.0/24 --interface=eth0','10.0.0.0/8 --interface=wlan0']"
hash="$(netalertx_hash secret)"
on="$(netalertx_override_json "$subnets" yes "$hash")"
off="$(netalertx_override_json "$subnets" no "")"
bare="$(netalertx_override_json "" no "")"
assert_eq "override with login" \
    "{\"SCAN_SUBNETS\":\"$subnets\",\"SETPWD_enable_password\":\"True\",\"SETPWD_password\":\"$hash\"}" "$on"
assert_eq "override without login" "{\"SCAN_SUBNETS\":\"$subnets\",\"SETPWD_enable_password\":\"False\"}" "$off"
assert_eq "override without subnets" '{"SETPWD_enable_password":"False"}' "$bare"
assert_eq "override login, no subnets" "{\"SETPWD_enable_password\":\"True\",\"SETPWD_password\":\"$hash\"}" \
    "$(netalertx_override_json "" yes "$hash")"

if [[ $have_python -eq 1 ]]; then
    assert_eq "override JSON: SCAN_SUBNETS" "$subnets" "$(json_get "$on" SCAN_SUBNETS)"
    assert_eq "override JSON: enable_password on" "True" "$(json_get "$on" SETPWD_enable_password)"
    assert_eq "override JSON: password hash" "$hash" "$(json_get "$on" SETPWD_password)"
    assert_eq "override JSON: enable_password off" "False" "$(json_get "$off" SETPWD_enable_password)"
    assert_eq "override JSON: no password when off" "MISSING" "$(json_get "$off" SETPWD_password)"
    assert_eq "override JSON: no SCAN_SUBNETS when empty" "MISSING" "$(json_get "$bare" SCAN_SUBNETS)"
    odd_subnets=$'[\'a"b\\c\',\'tab\there\']'
    assert_eq "override JSON escapes odd subnets" "$odd_subnets" \
        "$(json_get "$(netalertx_override_json "$odd_subnets" yes "$hash")" SCAN_SUBNETS)"
else
    skip "override JSON parse tests (python3 missing)"
fi

# --- netalertx_yaml_dq: the compose line decodes back to the same JSON -------------
assert_eq "yaml_dq escapes" '"{\"a\":\"b\\\\c\"}"' "$(netalertx_yaml_dq '{"a":"b\\c"}')"
if [[ $have_python -eq 1 ]] && python3 -c 'import yaml' 2>/dev/null; then
    for json in "$on" "$off" "$(netalertx_override_json $'[\'x"y\\\\z\']' yes "$hash")"; do
        line="APP_CONF_OVERRIDE: $(netalertx_yaml_dq "$json")"
        got="$(printf '%s\n' "$line" | python3 -c 'import sys,yaml; sys.stdout.write(yaml.safe_load(sys.stdin)["APP_CONF_OVERRIDE"])')"
        assert_eq "YAML scalar decodes to the JSON: $json" "$json" "$got"
    done
else
    skip "YAML decode tests (python3 yaml module missing)"
fi

# --- netalertx_conf_set / netalertx_apply_login -------------------------------------
conf="$TMP/app.conf"
printf '%s\n' "# header" "SCAN_SUBNETS=['--localnet']" "SETPWD_password = 'old'" "OTHER=1" "SETPWD_password='dup'" >"$conf"
chmod 0640 "$conf"
if netalertx_conf_set "$conf" SETPWD_password "'new'"; then pass "conf_set reports a change"; else fail "conf_set reports a change"; fi
assert_eq "conf_set replaces the first line and drops duplicates" \
    "$(printf '%s\n' "# header" "SCAN_SUBNETS=['--localnet']" "SETPWD_password='new'" "OTHER=1")" "$(cat "$conf")"
assert_eq "conf_set keeps the file mode" "640" "$(stat -c %a "$conf")"
if netalertx_conf_set "$conf" SETPWD_password "'new'"; then fail "conf_set unchanged returns false"; else pass "conf_set unchanged returns false"; fi
netalertx_conf_set "$conf" SETPWD_enable_password True || true
assert_eq "conf_set appends a missing key" "SETPWD_enable_password=True" "$(tail -n1 "$conf")"
netalertx_conf_set "$conf" SETPWD_enable_password_x 1 || true
assert_eq "conf_set does not touch a key with the same prefix" "SETPWD_enable_password=True" "$(grep '^SETPWD_enable_password=' "$conf")"

printf '%s\n' "SCAN_SUBNETS=['--localnet']" >"$conf"
netalertx_apply_login "$conf" yes "$hash" >/dev/null 2>&1
assert_eq "apply_login yes: password line" "SETPWD_password='$hash'" "$(grep '^SETPWD_password' "$conf")"
assert_eq "apply_login yes: enabled" "SETPWD_enable_password=True" "$(grep '^SETPWD_enable_password' "$conf")"
before="$(cat "$conf")"
netalertx_apply_login "$conf" yes "$hash" >/dev/null 2>&1
assert_eq "apply_login is idempotent" "$before" "$(cat "$conf")"
netalertx_apply_login "$conf" no "" >/dev/null 2>&1
assert_eq "apply_login no: disabled" "SETPWD_enable_password=False" "$(grep '^SETPWD_enable_password' "$conf")"
assert_eq "apply_login no: keeps one line per key" "1" "$(grep -c '^SETPWD_enable_password' "$conf")"

# --- netalertx_password: reuse of the saved password (root only) --------------------
if [[ $EUID -eq 0 ]]; then
    secret=/var/lib/rpi-setup/secrets/netalertx.env
    backup=""
    if [[ -e "$secret" ]]; then backup="$TMP/secret.bak"; cp -p "$secret" "$backup"; fi
    restore_secret() {
        if [[ -n "$backup" ]]; then cp -p "$backup" "$secret"; else rm -f "$secret"; fi
        rm -rf "$TMP"
    }
    trap restore_secret EXIT
    rm -f "$secret"

    NETALERTX_PASSWORD='my "own" pw'
    netalertx_pw=""
    netalertx_password >/dev/null 2>&1
    assert_eq "password: NETALERTX_PASSWORD wins" 'my "own" pw' "$netalertx_pw"
    assert_fails "password: a chosen one is not saved" test -e "$secret"

    NETALERTX_PASSWORD=""
    netalertx_pw=""
    out="$(netalertx_password 2>&1; printf '\nPW=%s' "$netalertx_pw")"
    first="${out##*PW=}"
    if [[ "$first" =~ ^[A-Za-z0-9]{20}$ ]]; then pass "password: generated 20 alphanumerics"; else fail "password: generated '$first'"; fi
    assert_contains "password: generated one is printed once" "$first" "${out%PW=*}"
    assert_eq "password: generated one is saved" "NETALERTX_PASSWORD=$first" "$(grep '^NETALERTX_PASSWORD=' "$secret")"
    assert_eq "password: secret file is root-only" "600" "$(stat -c %a "$secret")"

    out="$(netalertx_password 2>&1; printf '\nPW=%s' "$netalertx_pw")"
    assert_eq "password: re-run reuses the saved one" "$first" "${out##*PW=}"
    assert_lacks "password: reused one is not printed again" "$first" "${out%PW=*}"

    NETALERTX_PASSWORD='override'
    netalertx_password >/dev/null 2>&1
    assert_eq "password: setting wins over the saved one" "override" "$netalertx_pw"
    assert_eq "password: saved one is kept" "NETALERTX_PASSWORD=$first" "$(grep '^NETALERTX_PASSWORD=' "$secret")"

    printf 'OTHER=1\nNETALERTX_PASSWORD=\n' >"$secret"
    NETALERTX_PASSWORD=""
    netalertx_password >/dev/null 2>&1
    if [[ -n "$netalertx_pw" && "$netalertx_pw" != "$first" ]]; then pass "password: empty saved value generates a new one"; else fail "password: empty saved value gave '$netalertx_pw'"; fi
    assert_eq "password: other saved keys kept" "OTHER=1" "$(grep '^OTHER=' "$secret")"
else
    skip "password reuse tests (need root)"
fi

finish_tests
