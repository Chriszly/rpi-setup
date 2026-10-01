#!/usr/bin/env bash
# test-task-runner.sh - unit tests for tasks/runner.sh: setting checks, the
# platform name, the deploy command's argument checks and a full deploy
# against throw-away git repositories with a stub setup.sh.
# Nothing is downloaded and no runner is registered.
#
# Run: bash ci/test-task-runner.sh
# shellcheck disable=SC2016,SC2153
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/runner.sh"

# CI runs this under sudo; the deploy command's SUDO_USER check has its own case.
unset SUDO_USER
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_contains "runner registers its task" "runner|" "${TASKS[*]}"

# --- runner_check_settings ----------------------------------------------------
ok() { ( RUNNER_REPO="${R-me/rpi-private}" RUNNER_TOKEN="${K-}" RUNNER_NAME="${N-pi5}" \
         RUNNER_LABELS="${L-pi5}" RUNNER_BRANCHES="${B-main}" runner_check_settings ) >/dev/null 2>&1; }
assert_ok    "a filled repo and defaults are valid" ok
assert_fails "an empty RUNNER_REPO is refused" eval 'R= ok'
assert_contains "an empty RUNNER_REPO explains what to set" "private repository" \
    "$( (RUNNER_REPO='' RUNNER_TOKEN='' RUNNER_NAME=pi5 RUNNER_LABELS=pi5 RUNNER_BRANCHES=main runner_check_settings) 2>&1 || true)"
assert_fails "a URL instead of owner/name is refused" eval 'R=https://github.com/me/x ok'
assert_ok    "a token is accepted" eval 'K=AABBCC123 ok'
assert_fails "a token with odd characters is refused" eval 'K="abc;reboot" ok'
assert_fails "a bad runner name is refused" eval 'N="my pi" ok'
assert_ok    "several labels are valid" eval 'L=pi5,home ok'
assert_fails "labels with spaces are refused" eval 'L="pi5, home" ok'
assert_ok    "several branches are valid" eval 'B="main, next" ok'
assert_fails "a bad branch is refused" eval 'B="main;x" ok'

# --- runner_platform ----------------------------------------------------------
assert_eq "Pi 5 64-bit" linux-arm64 "$(runner_platform aarch64)"
assert_eq "x86_64" linux-x64 "$(runner_platform x86_64)"
assert_eq "32-bit Pi OS" linux-arm "$(runner_platform armv7l)"

# --- the generated deploy command ---------------------------------------------
script="$(runner_deploy_script /home/pi/rpi-setup "main,next")"
assert_ok "the deploy command is valid bash" bash -n <(printf '%s\n' "$script")
assert_contains "the deploy command knows the allowed branches" 'DP_BRANCHES=main\ next' "$script"

# --- deploy_run_args ----------------------------------------------------------
args() { ( DP_BRANCHES="main next"; deploy_run_args "$@" && printf '%s|%s|%s' "$DP_BRANCH" "$DP_CONFIG" "$DP_TASKS" ) 2>/dev/null; }
assert_eq "defaults to the first allowed branch" "main||" "$(args)"
assert_eq "tasks may be comma separated" "next||base pihole" "$(args --branch next --tasks base,pihole)"
assert_fails "a branch not in RUNNER_BRANCHES is refused" args --branch evil
assert_fails "a task with odd characters is refused" args --tasks 'base;reboot'
assert_fails "an unknown argument is refused" args --force
assert_fails "a missing settings file is refused" args --config "$tmp/nope.env"
if [[ $EUID -eq 0 ]] && id nobody >/dev/null 2>&1; then
    printf 'X=1\n' >"$tmp/root-only.env"; chmod 600 "$tmp/root-only.env"
    assert_fails "a settings file the sudo caller cannot read is refused" \
        eval 'SUDO_USER=nobody args --config "$tmp/root-only.env"'
else
    skip "sudo caller check (run with sudo to include it)"
fi

# --- a deploy against local repositories --------------------------------------
git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
git_q init --bare "$tmp/origin.git"
git_q clone "$tmp/origin.git" "$tmp/work"
cat >"$tmp/work/setup.sh" <<STUB
#!/usr/bin/env bash
echo "generated password: hunter2"
echo "\$* cfg=\$RPI_SETUP_CONFIG_DIR" >"$tmp/ran"
echo 'Summary:'
echo "  \$1 ok"
STUB
git_q -C "$tmp/work" add setup.sh
git_q -C "$tmp/work" commit -m one
git_q -C "$tmp/work" push origin main
git_q clone "$tmp/origin.git" "$tmp/pi"
echo two >"$tmp/work/two"
git_q -C "$tmp/work" add two
git_q -C "$tmp/work" commit -m two
git_q -C "$tmp/work" push origin main
printf 'WEB_TITLE=Mine\n' >"$tmp/settings.env"

deploy() {
    rm -f "$tmp/ran"
    (
        DP_DIR="$tmp/pi" DP_BRANCHES=main DP_DONE_FILE="$tmp/done" DP_CONFIG_DIR="$tmp/etc"
        DP_LOG_DIR="$tmp/log" DP_LOCK="$tmp/lock"
        deploy_run "$@"
    ) 2>&1
}
out="$(deploy --config "$tmp/settings.env" --tasks "base pihole")"
assert_eq "the checkout is updated to the branch tip" "$(git -C "$tmp/work" rev-parse HEAD)" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_eq "the settings are installed" "WEB_TITLE=Mine" "$(cat "$tmp/etc/rpi-setup.env")"
assert_eq "the settings are private" "600" "$(stat -c %a "$tmp/etc/rpi-setup.env")"
assert_eq "setup.sh runs the tasks with the installed settings" "base pihole cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_contains "the summary reaches the workflow log" "base ok" "$out"
if [[ "$out" == *hunter2* ]]; then
    fail "setup.sh's full output must stay on the Pi"
else
    pass "setup.sh's full output (passwords) stays out of the workflow log"
fi
assert_contains "the full output is kept on the Pi" "hunter2" "$(cat "$tmp"/log/deploy-*.log)"

out="$(deploy)"
assert_contains "no tasks and none recorded does nothing" "none recorded" "$out"
assert_ok "and runs no setup" test ! -e "$tmp/ran"
printf 'base\nweb\n' >"$tmp/done"
deploy >/dev/null
assert_eq "no tasks reruns the recorded ones" "base web cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_fails "a branch outside RUNNER_BRANCHES never touches the checkout" eval 'deploy --branch other >/dev/null'

finish_tests
