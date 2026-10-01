#!/usr/bin/env bash
# Task: runner - a GitHub Actions runner on this Pi for a PRIVATE repository
# of yours, so a manual "Deploy" workflow there can update the Pi: it pulls
# this public repo, installs your settings and reruns tasks with setup.sh.
# The runner only connects out to GitHub; no SSH key, Tailscale key or Pi
# address is stored at GitHub. Never register it to a public repository:
# pull requests from strangers could then run code on the Pi.
# Template workflow and private-repo layout: templates/private-repo/.
# Settings: RUNNER_* in config/rpi-setup.env (names in config/tasks/runner.env).
set -euo pipefail

TASKS+=("runner|GitHub runner for a manual Deploy workflow in your private repo")

RPI_RUNNER_USER=rpi-runner
RPI_RUNNER_DIR=/opt/rpi-runner
RPI_DEPLOY_CMD=/usr/local/sbin/rpi-setup-deploy
RPI_DEPLOY_SUDOERS=/etc/sudoers.d/rpi-setup-runner
# Tasks that finished at least once, one per line; written by setup.sh.
RPI_SETUP_DONE_FILE="${RPI_SETUP_DONE_FILE:-/var/lib/rpi-setup/tasks.done}"

run_runner() {
  : "${RUNNER_REPO:=}" "${RUNNER_TOKEN:=}" "${RUNNER_NAME:=}" "${RUNNER_LABELS:=}" "${RUNNER_BRANCHES:=main}"
  [[ -n "$RUNNER_NAME" ]] || RUNNER_NAME="$(hostname)"
  [[ -n "$RUNNER_LABELS" ]] || RUNNER_LABELS="$RUNNER_NAME"
  runner_check_settings

  git -C "$RPI_SETUP_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$RPI_SETUP_ROOT is not a git checkout; clone the repository with git so the Deploy workflow can update it."
  apt_install git curl jq tar sudo

  install -m 0755 -d "$(dirname "$RPI_DEPLOY_CMD")"
  if runner_deploy_script "$RPI_SETUP_ROOT" "$RUNNER_BRANCHES" | write_if_changed "$RPI_DEPLOY_CMD" 0755; then
    say "Wrote $RPI_DEPLOY_CMD"
  fi

  if ! id "$RPI_RUNNER_USER" >/dev/null 2>&1; then
    local uid
    uid="$(assign_uid "$RPI_RUNNER_USER")"
    groupadd --system --gid "$uid" "$RPI_RUNNER_USER"
    useradd --system --uid "$uid" --gid "$uid" --home-dir "$RPI_RUNNER_DIR" --shell /usr/sbin/nologin "$RPI_RUNNER_USER"
    say "Created user $RPI_RUNNER_USER ($uid)"
  fi
  install -m 0750 -o "$RPI_RUNNER_USER" -g "$RPI_RUNNER_USER" -d "$RPI_RUNNER_DIR"

  # The runner user may run exactly one command as root: the deploy command,
  # which checks its arguments before doing anything.
  local tmp
  tmp="$(mktemp)"
  printf '# Written by rpi-setup (tasks/runner.sh).\n%s ALL=(root) NOPASSWD: %s\n' "$RPI_RUNNER_USER" "$RPI_DEPLOY_CMD" >"$tmp"
  visudo -cqf "$tmp" || { rm -f "$tmp"; die 'The sudoers rule for the runner did not validate.'; }
  write_if_changed "$RPI_DEPLOY_SUDOERS" 0440 <"$tmp" && say "Wrote $RPI_DEPLOY_SUDOERS"
  rm -f "$tmp"

  if [[ ! -x "$RPI_RUNNER_DIR/config.sh" ]]; then
    runner_download "$RPI_RUNNER_DIR"
    "$RPI_RUNNER_DIR/bin/installdependencies.sh" >/dev/null
  fi

  if [[ -f "$RPI_RUNNER_DIR/.runner" ]]; then
    info "Runner already registered ($(jq -r '.agentName + " at " + .gitHubUrl' "$RPI_RUNNER_DIR/.runner" 2>/dev/null || echo 'see .runner'))"
  else
    [[ -n "$RUNNER_TOKEN" ]] || die "RUNNER_TOKEN is empty. In https://github.com/$RUNNER_REPO/settings/actions/runners/new copy the token after --token, put it in RUNNER_TOKEN (valid for one hour) and run: sudo bash setup.sh runner"
    ( cd "$RPI_RUNNER_DIR" &&
      runuser -u "$RPI_RUNNER_USER" -- ./config.sh --unattended --replace \
        --url "https://github.com/$RUNNER_REPO" --token "$RUNNER_TOKEN" \
        --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work ) ||
      die "Registering the runner failed. A token is valid for one hour; get a new one at https://github.com/$RUNNER_REPO/settings/actions/runners/new"
    say "Runner '$RUNNER_NAME' registered to $RUNNER_REPO (labels: $RUNNER_LABELS)"
    info 'The token is no longer needed; you can empty RUNNER_TOKEN.'
  fi

  ( cd "$RPI_RUNNER_DIR" && { ./svc.sh status >/dev/null 2>&1 || ./svc.sh install "$RPI_RUNNER_USER" >/dev/null; } && ./svc.sh start >/dev/null ) ||
    die "Could not start the runner service (see: cd $RPI_RUNNER_DIR && sudo ./svc.sh status)"
  say "Runner service running. Deploy from https://github.com/$RUNNER_REPO/actions with the 'Deploy to Pi' workflow."
  info "The deploy command accepts these branches of this repo: $RUNNER_BRANCHES"
}

# Dies naming the setting if a RUNNER_* value is unusable.
runner_check_settings() {
  local b
  [[ -n "$RUNNER_REPO" ]] ||
    die 'RUNNER_REPO is empty: set it to your private repository, e.g. Chriszly/rpi-private (see templates/private-repo/README.md).'
  [[ "$RUNNER_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "RUNNER_REPO must look like owner/name (got '$RUNNER_REPO')"
  [[ -z "$RUNNER_TOKEN" || "$RUNNER_TOKEN" =~ ^[A-Za-z0-9]+$ ]] ||
    die 'RUNNER_TOKEN must be the token shown after --token on the "New self-hosted runner" page.'
  [[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
    die "RUNNER_NAME may use letters, digits, '.', '_' and '-' (got '$RUNNER_NAME')"
  [[ "$RUNNER_LABELS" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] ||
    die "RUNNER_LABELS must be comma separated words such as pi5,home (got '$RUNNER_LABELS')"
  [[ -n "$RUNNER_BRANCHES" ]] || die 'RUNNER_BRANCHES must name at least one branch, e.g. main'
  for b in ${RUNNER_BRANCHES//,/ }; do
    if [[ ! "$b" =~ ^[A-Za-z0-9._/-]+$ || "$b" == -* ]] || ! git check-ref-format --branch "$b" >/dev/null 2>&1; then
      die "RUNNER_BRANCHES: '$b' is not a branch name"
    fi
  done
}

# The runner release asset name for CPU $1 (uname -m), e.g. linux-arm64.
runner_platform() {
  case "$1" in
    aarch64|arm64) echo linux-arm64 ;;
    x86_64|amd64) echo linux-x64 ;;
    armv7l|armv6l|armhf) echo linux-arm ;;
    *) die "No GitHub runner build for CPU '$1'" ;;
  esac
}

# Download and unpack the newest runner release into $1, checking the
# SHA-256 that GitHub publishes for the file.
runner_download() {
  local dir="$1" plat json url digest file
  plat="$(runner_platform "$(uname -m)")"
  json="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)" ||
    die 'Could not ask GitHub for the newest runner release; check the network and try again.'
  url="$(jq -r --arg p "$plat" '.assets[] | select(.name | test("^actions-runner-" + $p + "-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' <<<"$json" | head -n1)"
  digest="$(jq -r --arg u "$url" '.assets[] | select(.browser_download_url == $u) | .digest // ""' <<<"$json")"
  [[ -n "$url" ]] || die "The newest runner release has no $plat build; see https://github.com/actions/runner/releases"
  file="$(mktemp)"
  info "Downloading $url"
  curl -fsSL -o "$file" "$url" || { rm -f "$file"; die "Download failed: $url"; }
  if [[ "$digest" == sha256:* ]]; then
    echo "${digest#sha256:}  $file" | sha256sum -c --quiet - || { rm -f "$file"; die "Checksum mismatch for $url"; }
  else
    warn "GitHub listed no checksum for $url; it was downloaded over HTTPS but not verified."
  fi
  tar -xzf "$file" -C "$dir"
  rm -f "$file"
  chown -R "$RPI_RUNNER_USER:$RPI_RUNNER_USER" "$dir"
}

# Print the deploy command: its fixed settings, then the deploy_run_*
# functions below (so the unit tests exercise the code the runner calls).
runner_deploy_script() {
  local dir="$1" branches="$2"
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/runner.sh). Change the RUNNER_* settings and\n'
  printf '# re-run "sudo bash setup.sh runner" instead of editing this file.\n'
  printf '# Usage: sudo %s [--branch NAME] [--config FILE] [--tasks "a b"]\n' "$RPI_DEPLOY_CMD"
  printf 'set -euo pipefail\n'
  printf 'DP_DIR=%q\n' "$dir"
  printf 'DP_BRANCHES=%q\n' "${branches//,/ }"
  printf 'DP_DONE_FILE=%q\n' "$RPI_SETUP_DONE_FILE"
  printf 'DP_CONFIG_DIR=/etc/rpi-setup\n'
  printf 'DP_LOG_DIR=/var/log/rpi-setup-deploy\n'
  printf 'DP_LOCK=/run/rpi-setup-deploy.lock\n'
  declare -f deploy_run_git deploy_run_args deploy_run_tasks deploy_run_config deploy_run
  printf 'deploy_run "$@"\n'
}

# --- Code of the deploy command (uses only DP_* variables and plain tools) ---

# git in $DP_DIR as the user who owns the checkout, so root never leaves
# root-owned files in it.
deploy_run_git() {
  local owner
  owner="$(stat -c %U "$DP_DIR")"
  if [[ "$owner" == "$(id -un)" ]]; then
    git -C "$DP_DIR" "$@"
  else
    runuser -u "$owner" -- git -C "$DP_DIR" "$@"
  fi
}

# Parse and check the arguments into DP_BRANCH, DP_CONFIG and DP_TASKS.
# Everything comes from a workflow, so anything unexpected stops the deploy.
# shellcheck disable=SC2153  # DP_BRANCHES is set at the top of the deploy command
deploy_run_args() {
  DP_BRANCH="${DP_BRANCHES%% *}" DP_CONFIG='' DP_TASKS=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) DP_BRANCH="${2:-}"; shift 2 ;;
      --config) DP_CONFIG="${2:-}"; shift 2 ;;
      --tasks) DP_TASKS="${2:-}"; shift 2 ;;
      *) echo "rpi-setup-deploy: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  case " $DP_BRANCHES " in
    *" $DP_BRANCH "*) ;;
    *) echo "rpi-setup-deploy: branch '$DP_BRANCH' is not allowed (RUNNER_BRANCHES: $DP_BRANCHES)" >&2; return 2 ;;
  esac
  DP_TASKS="${DP_TASKS//,/ }"
  if [[ ! "$DP_TASKS" =~ ^[a-z0-9_\ -]*$ ]]; then
    echo "rpi-setup-deploy: task names may only use a-z, 0-9, '-' and '_' (got '$DP_TASKS')" >&2
    return 2
  fi
  if [[ -n "$DP_CONFIG" && ! -f "$DP_CONFIG" ]]; then
    echo "rpi-setup-deploy: settings file '$DP_CONFIG' not found" >&2
    return 2
  fi
  # Called through sudo: only take a settings file the caller could read
  # itself, so the runner cannot copy other root-only files around.
  if [[ -n "$DP_CONFIG" && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] &&
     ! runuser -u "$SUDO_USER" -- test -r "$DP_CONFIG"; then
    echo "rpi-setup-deploy: $SUDO_USER cannot read '$DP_CONFIG'" >&2
    return 2
  fi
  return 0
}

# Tasks to run: DP_TASKS, else every task that finished on this Pi.
deploy_run_tasks() {
  local -a t
  read -r -a t <<<"$DP_TASKS"
  if [[ ${#t[@]} -gt 0 ]]; then
    printf '%s\n' "${t[@]}"
  elif [[ -f "$DP_DONE_FILE" ]]; then
    grep -E '^[a-z0-9_-]+$' "$DP_DONE_FILE" || true
  fi
}

# Install settings file $1 as $DP_CONFIG_DIR/rpi-setup.env (root only).
deploy_run_config() {
  install -m 0700 -d "$DP_CONFIG_DIR"
  install -m 0600 "$1" "$DP_CONFIG_DIR/rpi-setup.env"
  echo "rpi-setup-deploy: installed new settings in $DP_CONFIG_DIR/rpi-setup.env"
}

# One deploy. setup.sh's full output (it prints generated passwords) goes
# to a root-only log on the Pi; only the summary reaches the workflow log.
deploy_run() {
  deploy_run_args "$@" || return $?
  exec 9>"$DP_LOCK"
  flock -n 9 || { echo 'rpi-setup-deploy: another deploy is running' >&2; return 1; }
  local old new log rc=0
  local -a tasks
  deploy_run_git fetch --quiet origin "$DP_BRANCH"
  old="$(deploy_run_git rev-parse HEAD)"
  if [[ "$(deploy_run_git rev-parse --abbrev-ref HEAD)" != "$DP_BRANCH" ]]; then
    deploy_run_git checkout --quiet "$DP_BRANCH" 2>/dev/null ||
      deploy_run_git checkout --quiet -b "$DP_BRANCH" FETCH_HEAD
  fi
  deploy_run_git merge --ff-only --quiet FETCH_HEAD || {
    echo "rpi-setup-deploy: cannot fast-forward $DP_DIR to origin/$DP_BRANCH; local commits or changes are in the way (git -C $DP_DIR status)" >&2
    return 1
  }
  new="$(deploy_run_git rev-parse HEAD)"
  echo "rpi-setup-deploy: $DP_DIR on $DP_BRANCH at ${new:0:7} (was ${old:0:7})"
  [[ -z "$DP_CONFIG" ]] || deploy_run_config "$DP_CONFIG"
  mapfile -t tasks < <(deploy_run_tasks)
  if [[ ${#tasks[@]} -eq 0 ]]; then
    echo 'rpi-setup-deploy: no tasks given and none recorded on this Pi; pass --tasks'
    return 0
  fi
  install -m 0700 -d "$DP_LOG_DIR"
  log="$DP_LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
  echo "rpi-setup-deploy: running setup.sh ${tasks[*]} (full output on the Pi: $log)"
  ( umask 077; RPI_SETUP_CONFIG_DIR="$DP_CONFIG_DIR" bash "$DP_DIR/setup.sh" "${tasks[@]}" </dev/null >"$log" 2>&1 ) || rc=$?
  sed -n '/^Summary:/,$p' "$log"
  [[ $rc -eq 0 ]] || echo "rpi-setup-deploy: setup.sh failed (exit $rc); details on the Pi: sudo less $log" >&2
  return "$rc"
}
