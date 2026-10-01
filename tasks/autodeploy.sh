#!/usr/bin/env bash
# Task: autodeploy - keep this Pi on the latest rpi-setup without logging in.
# A systemd timer fetches this checkout's branch from its public repository
# (HTTPS, no credentials), waits until GitHub shows the commit's CI checks
# green, fast-forwards the checkout and reruns the Pi's tasks with setup.sh.
# Nothing connects in to the Pi, so no SSH key or address goes to GitHub.
# Settings: AUTODEPLOY_* in config/rpi-setup.env (names in config/tasks/autodeploy.env).
set -euo pipefail

TASKS+=("autodeploy|Deploy new commits of this repo automatically (systemd timer)")

RPI_DEPLOY_SCRIPT=/usr/local/sbin/rpi-setup-deploy
RPI_DEPLOY_UNIT=rpi-setup-deploy
# Tasks that finished at least once, one per line; written by setup.sh.
RPI_SETUP_DONE_FILE="${RPI_SETUP_DONE_FILE:-/var/lib/rpi-setup/tasks.done}"

run_autodeploy() {
  : "${AUTODEPLOY_BRANCH:=main}" "${AUTODEPLOY_INTERVAL:=15min}" "${AUTODEPLOY_TASKS:=}" "${AUTODEPLOY_REQUIRE_CI:=yes}"
  autodeploy_check_settings
  local ci=no
  if setting_on AUTODEPLOY_REQUIRE_CI; then ci=yes; fi

  git -C "$RPI_SETUP_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$RPI_SETUP_ROOT is not a git checkout; clone the repository with git to use autodeploy."
  local url
  url="$(git -C "$RPI_SETUP_ROOT" remote get-url origin 2>/dev/null)" ||
    die "The checkout in $RPI_SETUP_ROOT has no 'origin' remote to fetch from."
  if [[ "$ci" == yes && -z "$(autodeploy_run_slug "$url")" ]]; then
    die "AUTODEPLOY_REQUIRE_CI=yes needs a github.com origin (found '$url'); set it to no for another host."
  fi
  apt_install git curl jq

  install -m 0755 -d "$(dirname "$RPI_DEPLOY_SCRIPT")"
  if autodeploy_script "$RPI_SETUP_ROOT" "$AUTODEPLOY_BRANCH" "$AUTODEPLOY_TASKS" "$ci" |
     write_if_changed "$RPI_DEPLOY_SCRIPT" 0700; then
    say "Wrote $RPI_DEPLOY_SCRIPT"
  fi

  local units=0
  printf '%s\n' \
    '[Unit]' \
    'Description=rpi-setup automatic deploy (tasks/autodeploy.sh)' \
    'Wants=network-online.target' \
    'After=network-online.target' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$RPI_DEPLOY_SCRIPT" \
    'Nice=10' |
    write_if_changed "/etc/systemd/system/$RPI_DEPLOY_UNIT.service" && units=1
  printf '%s\n' \
    '[Unit]' \
    'Description=Check for new rpi-setup commits' \
    '' \
    '[Timer]' \
    'OnBootSec=5min' \
    "OnUnitActiveSec=$AUTODEPLOY_INTERVAL" \
    'RandomizedDelaySec=1min' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' |
    write_if_changed "/etc/systemd/system/$RPI_DEPLOY_UNIT.timer" && units=1
  if [[ $units -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart "$RPI_DEPLOY_UNIT.timer" 2>/dev/null || true
  fi
  systemctl enable --now "$RPI_DEPLOY_UNIT.timer"
  say "Autodeploy active: checks '$AUTODEPLOY_BRANCH' every $AUTODEPLOY_INTERVAL${ci/yes/ and deploys commits whose CI is green}${ci/no/}"
  info "Tasks it reruns: ${AUTODEPLOY_TASKS:-every task that finished on this Pi (see $RPI_SETUP_DONE_FILE)}"
  info "Deploy now: sudo $RPI_DEPLOY_SCRIPT   Watch: journalctl -u $RPI_DEPLOY_UNIT"
  info "Pause: sudo systemctl disable --now $RPI_DEPLOY_UNIT.timer"
}

# Dies naming the setting if an AUTODEPLOY_* value is unusable.
autodeploy_check_settings() {
  local b="${AUTODEPLOY_BRANCH:-}" iv="${AUTODEPLOY_INTERVAL:-}" t known e
  if [[ -z "$b" || ! "$b" =~ ^[A-Za-z0-9._/-]+$ || "$b" == -* ]] ||
     ! git check-ref-format --branch "$b" >/dev/null 2>&1; then
    die "AUTODEPLOY_BRANCH must be a branch name such as main (got '$b')"
  fi
  [[ "$iv" =~ ^[0-9]+[[:space:]]*(s|sec|m|min|h|hr|d|day)?$ ]] ||
    die "AUTODEPLOY_INTERVAL must be a time such as 15min, 1h or 1d (got '$iv')"
  for t in ${AUTODEPLOY_TASKS//,/ }; do
    known=0
    for e in "${TASKS[@]}"; do [[ "${e%%|*}" == "$t" ]] && known=1; done
    [[ $known -eq 1 ]] || die "AUTODEPLOY_TASKS: unknown task '$t' (see: bash setup.sh --list)"
  done
  setting_on AUTODEPLOY_REQUIRE_CI || true
}

# Print the standalone deploy script: its settings, then the autodeploy_run_*
# functions below (so the unit tests exercise the code that runs on the timer).
autodeploy_script() {
  local dir="$1" branch="$2" tasks="$3" ci="$4"
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/autodeploy.sh). Change the AUTODEPLOY_* settings\n'
  printf '# and re-run "sudo bash setup.sh autodeploy" instead of editing this file.\n'
  printf 'set -euo pipefail\n'
  printf 'AD_DIR=%q\n' "$dir"
  printf 'AD_BRANCH=%q\n' "$branch"
  printf 'AD_TASKS=%q\n' "${tasks//,/ }"
  printf 'AD_REQUIRE_CI=%q\n' "$ci"
  printf 'AD_DONE_FILE=%q\n' "$RPI_SETUP_DONE_FILE"
  printf 'AD_STATE=/var/lib/rpi-setup/deployed\n'
  printf 'AD_LOCK=/run/rpi-setup-deploy.lock\n'
  declare -f autodeploy_run_slug autodeploy_run_git autodeploy_run_checks autodeploy_run_ci \
    autodeploy_run_pick autodeploy_run_tasks autodeploy_run
  printf 'autodeploy_run "$@"\n'
}

# --- Code of the deploy script (uses only AD_* variables and plain tools) ---

# owner/repo of a github.com remote URL $1, or nothing for any other host.
autodeploy_run_slug() {
  local u="${1%.git}"
  u="${u%/}"
  if [[ "$u" =~ ^(https://|ssh://git@|git@)github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

# git in $AD_DIR as the user who owns the checkout, so root never leaves
# root-owned files in it (and git's safe.directory check passes).
autodeploy_run_git() {
  local owner
  owner="$(stat -c %U "$AD_DIR")"
  if [[ "$owner" == "$(id -un)" ]]; then
    git -C "$AD_DIR" "$@"
  else
    runuser -u "$owner" -- git -C "$AD_DIR" "$@"
  fi
}

# GitHub's check runs of commit $2 in repo $1 as JSON (public API, no token).
autodeploy_run_checks() {
  curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/commits/$2/check-runs?per_page=100"
}

# CI state of commit $2 in repo $1: prints green, red or pending ("pending"
# also when the commit has no checks at all, e.g. a docs-only change).
autodeploy_run_ci() {
  local json
  json="$(autodeploy_run_checks "$1" "$2")" || { echo pending; return 0; }
  jq -r '
    [.check_runs[]? | {s: .status, c: (.conclusion // "")}] as $r
    | if ($r | length) == 0 then "pending"
      elif any($r[]; .s != "completed") then "pending"
      elif all($r[]; .c == "success" or .c == "skipped" or .c == "neutral") then "green"
      else "red" end' <<<"$json" 2>/dev/null || echo pending
}

# The commit to deploy: the newest of the (at most 20) new commits on the
# branch whose CI is green, or the branch tip when CI is not required.
# Prints nothing when there is nothing to deploy.
autodeploy_run_pick() {
  local head="$1" tip="$2" slug="$3" sha state
  [[ "$head" != "$tip" ]] || return 0
  if [[ "$AD_REQUIRE_CI" != yes ]]; then
    printf '%s\n' "$tip"
    return 0
  fi
  while IFS= read -r sha; do
    state="$(autodeploy_run_ci "$slug" "$sha")"
    echo "rpi-setup-deploy: ${sha:0:7} CI $state" >&2
    if [[ "$state" == green ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
  done < <(autodeploy_run_git rev-list --first-parent --max-count=20 "$head..$tip")
  return 0
}

# Tasks to rerun: AD_TASKS, else every task that finished on this Pi.
autodeploy_run_tasks() {
  if [[ -n "$AD_TASKS" ]]; then
    local -a t
    read -r -a t <<<"$AD_TASKS"
    printf '%s\n' "${t[@]}"
  elif [[ -f "$AD_DONE_FILE" ]]; then
    grep -E '^[a-z0-9_-]+$' "$AD_DONE_FILE" || true
  fi
}

# One deploy round. Exit 0 when nothing changed or the deploy worked.
autodeploy_run() {
  exec 9>"$AD_LOCK"
  flock -n 9 || { echo 'rpi-setup-deploy: another deploy is running' >&2; return 0; }
  local head tip slug pick rc=0
  local -a tasks
  autodeploy_run_git fetch --quiet origin "$AD_BRANCH"
  head="$(autodeploy_run_git rev-parse HEAD)"
  tip="$(autodeploy_run_git rev-parse FETCH_HEAD)"
  slug="$(autodeploy_run_slug "$(autodeploy_run_git remote get-url origin)")"
  pick="$(autodeploy_run_pick "$head" "$tip" "$slug")"
  if [[ -z "$pick" ]]; then
    echo "rpi-setup-deploy: nothing to deploy (on ${head:0:7}, branch at ${tip:0:7})"
    return 0
  fi
  autodeploy_run_git merge --ff-only --quiet "$pick" || {
    echo "rpi-setup-deploy: cannot fast-forward $AD_DIR to ${pick:0:7}; local commits or changes are in the way (git -C $AD_DIR status)" >&2
    return 1
  }
  echo "rpi-setup-deploy: updated $AD_DIR ${head:0:7} -> ${pick:0:7}"
  mapfile -t tasks < <(autodeploy_run_tasks)
  if [[ ${#tasks[@]} -gt 0 ]]; then
    bash "$AD_DIR/setup.sh" "${tasks[@]}" </dev/null || rc=$?
  else
    echo 'rpi-setup-deploy: no tasks to rerun (set AUTODEPLOY_TASKS)'
  fi
  mkdir -p "$(dirname "$AD_STATE")"
  printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pick" "$([[ $rc -eq 0 ]] && echo ok || echo failed)" >"$AD_STATE"
  if [[ $rc -ne 0 ]]; then
    echo "rpi-setup-deploy: setup.sh failed (exit $rc); see /var/log/rpi-setup.log" >&2
  fi
  return "$rc"
}
