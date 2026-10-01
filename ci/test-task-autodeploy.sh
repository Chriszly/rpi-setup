#!/usr/bin/env bash
# test-task-autodeploy.sh - unit tests for tasks/autodeploy.sh: remote URL
# parsing, setting checks, CI state from GitHub's check runs, which commit is
# picked and a full deploy round against throw-away git repositories.
# GitHub is never contacted: autodeploy_run_checks is replaced by a stub.
#
# Run: bash ci/test-task-autodeploy.sh
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/ci/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=("base|x" "docker|x" "pihole|x")
. "$ROOT/tasks/autodeploy.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_contains "autodeploy registers its task" "autodeploy|" "${TASKS[*]}"

# --- autodeploy_run_slug ------------------------------------------------------
assert_eq "slug from an https URL" "Chriszly/rpi-setup" "$(autodeploy_run_slug https://github.com/Chriszly/rpi-setup.git)"
assert_eq "slug without .git" "Chriszly/rpi-setup" "$(autodeploy_run_slug https://github.com/Chriszly/rpi-setup)"
assert_eq "slug from an ssh URL" "a/b" "$(autodeploy_run_slug git@github.com:a/b.git)"
assert_eq "no slug for another host" "" "$(autodeploy_run_slug https://gitlab.com/a/b.git)"
assert_eq "no slug for a lookalike host" "" "$(autodeploy_run_slug https://github.com.evil.example/a/b)"

# --- autodeploy_check_settings ------------------------------------------------
ok() { ( AUTODEPLOY_BRANCH="${B-main}" AUTODEPLOY_INTERVAL="${I-15min}" AUTODEPLOY_TASKS="${T-}" \
         AUTODEPLOY_REQUIRE_CI="${C-yes}" autodeploy_check_settings ) >/dev/null 2>&1; }
assert_ok    "defaults are valid" ok
assert_ok    "a task list is valid" eval 'T="base, pihole" ok'
assert_fails "an unknown task is refused" eval 'T="base pihol" ok'
assert_fails "a bad branch is refused" eval 'B="main;reboot" ok'
assert_fails "a branch starting with - is refused" eval 'B="-x" ok'
assert_ok    "1h is a valid interval" eval 'I=1h ok'
assert_fails "a bad interval is refused" eval 'I="soon" ok'
assert_fails "a bad yes/no is refused" eval 'C=maybe ok'

# --- autodeploy_run_ci --------------------------------------------------------
ci() { CHECKS="$1" bash -c '
  . "$1/lib/common.sh"; declare -a TASKS=(); . "$1/tasks/autodeploy.sh"
  autodeploy_run_checks() { printf "%s" "$CHECKS"; }
  autodeploy_run_ci a/b 123' _ "$ROOT"; }
assert_eq "all checks passed is green" green \
    "$(ci '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}')"
assert_eq "one failed check is red" red \
    "$(ci '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}')"
assert_eq "a running check is pending" pending \
    "$(ci '{"check_runs":[{"status":"in_progress","conclusion":null},{"status":"completed","conclusion":"success"}]}')"
assert_eq "no checks is pending" pending "$(ci '{"total_count":0,"check_runs":[]}')"
assert_eq "an API error is pending" pending "$(ci 'rate limit')"

# --- the generated script -----------------------------------------------------
script="$(autodeploy_script /home/pi/rpi-setup main "base,pihole" yes)"
assert_ok "the deploy script is valid bash" bash -n <(printf '%s\n' "$script")
assert_contains "the deploy script follows the branch" "AD_BRANCH=main" "$script"
assert_contains "the deploy script lists the tasks" 'AD_TASKS=base\ pihole' "$script"

# --- a deploy round against local repositories --------------------------------
git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
git_q init --bare "$tmp/origin.git"
git_q clone "$tmp/origin.git" "$tmp/work"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/ran"\n' "$tmp" >"$tmp/work/setup.sh"
git_q -C "$tmp/work" add setup.sh
git_q -C "$tmp/work" commit -m one
git_q -C "$tmp/work" push origin main
git_q clone "$tmp/origin.git" "$tmp/pi"
first="$(git -C "$tmp/pi" rev-parse HEAD)"
for n in two three; do
    echo "$n" >"$tmp/work/$n"
    git_q -C "$tmp/work" add "$n"
    git_q -C "$tmp/work" commit -m "$n"
done
git_q -C "$tmp/work" push origin main
two="$(git -C "$tmp/work" rev-parse HEAD~1)"
three="$(git -C "$tmp/work" rev-parse HEAD)"

# round CI_STATE_OF_TIP TASKS - one deploy round with GitHub stubbed.
round() {
    rm -f "$tmp/ran"
    (
        AD_DIR="$tmp/pi" AD_BRANCH=main AD_TASKS="$2" AD_REQUIRE_CI=yes
        AD_DONE_FILE="$tmp/done" AD_STATE="$tmp/state/deployed" AD_LOCK="$tmp/lock"
        autodeploy_run_slug() { echo a/b; }
        autodeploy_run_ci() { if [[ "$2" == "$three" ]]; then echo "$TIP"; else echo green; fi; }
        TIP="$1" autodeploy_run
    ) 2>&1
}
out="$(round red "")"
assert_eq "a red tip deploys the newest green commit" "$two" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_contains "the round says what it updated" "-> ${two:0:7}" "$out"
assert_ok "with no recorded tasks nothing is rerun" test ! -e "$tmp/ran"
printf 'base\npihole\n' >"$tmp/done"
out="$(round green "")"
assert_eq "a green tip is deployed" "$three" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_eq "the recorded tasks are rerun" "base pihole" "$(cat "$tmp/ran")"
assert_contains "the deployed commit is recorded" "$three ok" "$(cat "$tmp/state/deployed")"
out="$(round green "docker")"
assert_contains "an up-to-date Pi does nothing" "nothing to deploy" "$out"
assert_ok "nothing is rerun when nothing changed" test ! -e "$tmp/ran"

echo four >"$tmp/work/four"; git_q -C "$tmp/work" add four; git_q -C "$tmp/work" commit -m four
git_q -C "$tmp/work" push origin main
three="$(git -C "$tmp/work" rev-parse HEAD)"   # the new tip
out="$(round pending "docker")"
assert_eq "a pending tip waits" "$(git -C "$tmp/work" rev-parse HEAD~1)" "$(git -C "$tmp/pi" rev-parse HEAD)"
out="$(round green "docker")"
assert_eq "AUTODEPLOY_TASKS decides what is rerun" "docker" "$(cat "$tmp/ran")"

finish_tests
