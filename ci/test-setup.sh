#!/usr/bin/env bash
# test-setup.sh - tests for setup.sh's task registry, argument parsing and
# interactive menu. No task is ever executed: the CLI tests only use inputs
# that make setup.sh exit before run_tasks (unknown task, empty selection).
#
# Run: bash ci/test-setup.sh        (sudo bash ci/test-setup.sh for the root-only tests)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
# Sourcing setup.sh loads lib/common.sh and every tasks/*.sh without running main().
. "$ROOT/setup.sh"

# --- Task registry ------------------------------------------------------------
task_files=("$ROOT"/tasks/*.sh)
assert_eq "every tasks/*.sh registers exactly one task" "${#task_files[@]}" "${#TASKS[@]}"

names=()
for entry in "${TASKS[@]}"; do
    name="$(task_name "$entry")"
    desc="$(task_desc "$entry")"
    names+=("$name")
    if [[ "$(type -t "run_${name}")" == "function" ]]; then
        pass "task '$name' has a run_${name} handler"
    else
        fail "task '$name' has no run_${name} handler (setup.sh would silently skip it)"
    fi
    if [[ -n "$desc" && "$desc" != "$entry" ]]; then
        pass "task '$name' has a description"
    else
        fail "task '$name' is missing the '|description' part"
    fi
    if [[ -f "$ROOT/tasks/$name.sh" ]]; then
        pass "task '$name' lives in tasks/$name.sh"
    else
        fail "task '$name' is registered by a file that is not tasks/$name.sh"
    fi
done
dupes="$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
assert_eq "task names are unique" "" "$dupes"

# --- name_to_nums / dedupe ----------------------------------------------------
first="$(task_name "${TASKS[0]}")"
last="$(task_name "${TASKS[-1]}")"
assert_eq "name_to_nums maps the first task to 1" "1" "$(name_to_nums "$first")"
assert_eq "name_to_nums maps the last task to N" "${#TASKS[@]}" "$(name_to_nums "$last")"
assert_eq "name_to_nums keeps argument order" "${#TASKS[@]} 1" "$(name_to_nums "$last" "$first" | xargs)"
assert_fails "name_to_nums dies on an unknown task" name_to_nums no-such-task
assert_contains "name_to_nums names the unknown task" "unknown task: no-such-task" \
    "$( (name_to_nums no-such-task) 2>&1 || true)"

assert_eq "dedupe removes repeats, keeps first occurrence order" "1 3 2" "$(dedupe 1 1 3 2 3 | xargs)"
assert_eq "dedupe drops empty entries" "4" "$(dedupe "" 4 "" | xargs)"

# --- prompt_selection ---------------------------------------------------------
# The '> ' prompt must go to stderr; anything on stdout is parsed as a task number.
assert_eq "prompt_selection parses comma-separated numbers" "1 3" "$(printf '1,3\n' | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection parses space-separated numbers" "2 4" "$(printf '2 4\n' | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection expands 'all'" "$(seq 1 "${#TASKS[@]}" | xargs)" "$(printf 'all\n' | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection returns nothing for empty input" "" "$(printf '\n' | prompt_selection 2>/dev/null)"
assert_eq "prompt_selection ignores non-numeric tokens" "2" "$(printf 'abc 2 x\n' | prompt_selection 2>/dev/null | xargs)"
# main() does nums=($(prompt_selection)) under 'set -e', so a non-zero return
# here would silently kill setup.sh instead of printing "Cancelled.".
assert_ok "prompt_selection exits 0 on non-numeric input"  eval "printf 'abc\n' | prompt_selection"
assert_ok "prompt_selection exits 0 on a trailing non-numeric token" eval "printf '1 x\n' | prompt_selection"
assert_eq "prompt_selection writes the prompt to stderr, not stdout" "> " "$(printf '\n' | prompt_selection 2>&1 >/dev/null)"

# --- Task helpers -------------------------------------------------------------
tmp="$(mktemp -d)"
# Debian's netdata.conf ships localhost-only; the dashboard must reach the LAN.
printf '[global]\n\tbind socket to IP = 127.0.0.1\n[web]\n\tbind to = localhost\n' >"$tmp/netdata.conf"
assert_ok "netdata_listen_on_lan rewrites a localhost bind" netdata_listen_on_lan "$tmp/netdata.conf"
assert_eq "netdata_listen_on_lan leaves no localhost bind behind" "0" \
    "$(grep -Ec '127\.0\.0\.1|localhost' "$tmp/netdata.conf" || true)"
assert_contains "netdata_listen_on_lan binds 0.0.0.0" "bind socket to IP = 0.0.0.0" "$(cat "$tmp/netdata.conf")"
assert_fails "netdata_listen_on_lan reports nothing to change on a re-run" netdata_listen_on_lan "$tmp/netdata.conf"
assert_fails "netdata_listen_on_lan tolerates a missing file" netdata_listen_on_lan "$tmp/missing.conf"

printf 'server {\n\tlisten 80 default_server;\n\tlisten [::]:80 default_server;\n\t# listen 443 ssl default_server;\n}\n' >"$tmp/site"
nginx_move_port "$tmp/site" 80 8080
assert_contains "nginx_move_port moves the IPv4 listen" "listen 8080 default_server;" "$(cat "$tmp/site")"
assert_contains "nginx_move_port moves the IPv6 listen" "listen [::]:8080 default_server;" "$(cat "$tmp/site")"
assert_contains "nginx_move_port leaves other ports alone" "# listen 443 ssl" "$(cat "$tmp/site")"
rm -rf "$tmp"

# raspi-config's nonint mode reads 0 as "enable": "do_ssh 1" switches SSH off
# and locks out a headless Pi after its next reboot.
assert_contains "base enables SSH (do_ssh 0)" "do_ssh 0" "$(declare -f run_base)"
if [[ "$(declare -f run_base)" == *"do_ssh 1"* ]]; then
    fail "base must never call 'raspi-config nonint do_ssh 1' (that disables SSH)"
else
    pass "base never disables SSH"
fi
assert_contains "docker refreshes apt after adding its repository" "apt_update_now" "$(declare -f run_docker)"

# --- CLI: --list works without root -------------------------------------------
listing="$(bash "$ROOT/setup.sh" --list)"
for n in "${names[@]}"; do
    assert_contains "--list shows task '$n'" " $n " "$listing"
done

# --- CLI: root handling -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    assert_fails "setup.sh refuses to run tasks as non-root" bash "$ROOT/setup.sh" "$first"
    assert_contains "setup.sh explains it needs root" "run as root" \
        "$(bash "$ROOT/setup.sh" "$first" 2>&1 || true)"
    skip "root-only CLI tests (run with sudo to include them)"
else
    out="$(bash "$ROOT/setup.sh" no-such-task 2>&1 || true)"
    assert_fails "setup.sh exits non-zero on an unknown task" bash "$ROOT/setup.sh" no-such-task
    assert_contains "setup.sh reports the unknown task" "unknown task: no-such-task" "$out"

    out="$(printf '\n' | bash "$ROOT/setup.sh" 2>&1)"
    assert_contains "empty menu input cancels" "Cancelled." "$out"
    assert_contains "menu lists the tasks" " $first " "$out"

    out="$(printf 'abc\n' | bash "$ROOT/setup.sh" 2>&1)"
    assert_contains "non-numeric menu input cancels" "Cancelled." "$out"

    out="$(printf '1,2\n' | bash "$ROOT/setup.sh" --list 2>&1)"
    assert_contains "--list never prompts even with piped input" " $first " "$out"
fi

finish_tests
