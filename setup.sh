#!/usr/bin/env bash
# rpi-setup - easy way to provision a Raspberry Pi for different tasks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

declare -a TASKS=()
for f in "$SCRIPT_DIR"/tasks/*.sh; do
  . "$f"
done

[[ ${#TASKS[@]} -gt 0 ]] || die 'No tasks found under tasks/'

task_name() { printf '%s' "${1%%|*}"; }
task_desc() { printf '%s' "${1#*|}"; }

print_tasks() {
  local i=1 e
  for e in "${TASKS[@]}"; do
    printf '  %3d) %-14s %s\n' "$i" "$(task_name "$e")" "$(task_desc "$e")"
    i=$((i + 1))
  done
}

name_to_nums() {
  local name i found
  for name in "$@"; do
    found=0
    for i in "${!TASKS[@]}"; do
      if [[ "$(task_name "${TASKS[$i]}")" == "$name" ]]; then
        echo $((i + 1))
        found=1
        break
      fi
    done
    [[ $found -eq 1 ]] || die "unknown task: $name"
  done
}

dedupe() {
  local -A seen
  local x
  for x in "$@"; do
    [[ -z "$x" ]] && continue
    [[ -n "${seen[$x]+x}" ]] && continue
    echo "$x"
    seen[$x]=1
  done
}

prompt_selection() {
  local line p
  printf '> ' >&2
  IFS= read -r line
  line="${line//,/ }"
  [[ -z "${line// /}" ]] && return
  if [[ "$line" == "all" ]]; then
    seq 1 ${#TASKS[@]}
    return
  fi
  # Use if/then rather than '[[ ]] && echo': a trailing non-numeric token would
  # otherwise make the function return 1, and 'nums=($(prompt_selection))' in
  # main() would then abort the script under 'set -e' instead of cancelling.
  for p in $line; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then echo "$p"; fi
  done
  return 0
}

# Tasks that need another task first: TASK_NEEDS[task]="dep ...". A missing
# dependency is added to the run unless it is already installed (dep_installed).
declare -A TASK_NEEDS=(
  [netalertx]=docker
  [teamspeak]=docker
)

# True if dependency $1 is already on this system, so it need not run again.
dep_installed() {
  case "$1" in
    docker) command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Turn the selected task names into PLAN, the order they run in: missing
# dependencies are added, base runs first, a dependency runs before the tasks
# that need it, and everything else keeps the order it was given in.
declare -a PLAN=()
declare -A _PLAN_SELECTED=() _PLAN_PLACED=()
plan_tasks() {
  local -a wanted=()
  local name dep
  _PLAN_SELECTED=()
  _PLAN_PLACED=()
  PLAN=()
  for name in "$@"; do
    [[ -n "${_PLAN_SELECTED[$name]+x}" ]] && continue
    _PLAN_SELECTED[$name]=1
    wanted+=("$name")
  done
  for name in "${wanted[@]}"; do
    for dep in ${TASK_NEEDS[$name]:-}; do
      [[ -n "${_PLAN_SELECTED[$dep]+x}" ]] && continue
      dep_installed "$dep" && continue
      info "Adding task '$dep' because '$name' needs it."
      _PLAN_SELECTED[$dep]=1
      wanted+=("$dep")
    done
  done
  if [[ -n "${_PLAN_SELECTED[base]+x}" ]]; then _plan_place base; fi
  for name in "${wanted[@]}"; do _plan_place "$name"; done
}

_plan_place() {
  local t="$1" d
  [[ -n "${_PLAN_PLACED[$t]+x}" ]] && return 0
  _PLAN_PLACED[$t]=1
  for d in ${TASK_NEEDS[$t]:-}; do
    if [[ -n "${_PLAN_SELECTED[$d]+x}" ]]; then _plan_place "$d"; fi
  done
  PLAN+=("$t")
}

# Parse the settings file of every selected task before running any, so a typo
# in the last task's file stops the run before the first task changes anything.
check_task_configs() {
  local name
  for name in "$@"; do
    ( load_task_config "$name" ) >/dev/null
  done
}

# Description of the task named $1.
task_desc_of() {
  local entry
  for entry in "${TASKS[@]}"; do
    if [[ "$(task_name "$entry")" == "$1" ]]; then task_desc "$entry"; fi
  done
}

# Run tasks by name. Each runs in a subshell, so a failing command or 'die'
# ends only that task; the run goes on and TASK_RESULT records ok, failed or
# skipped. RUN_FAILED becomes 1 if a task failed or was skipped because a
# dependency failed. Call it plainly, never in a condition such as "run_tasks ||":
# bash would then ignore errexit inside every task.
declare -A TASK_RESULT=()
RUN_FAILED=0
run_tasks() {
  local name dep rc blocked
  TASK_RESULT=()
  RUN_FAILED=0
  for name in "$@"; do
    hr
    if [[ "$(type -t "run_${name}")" != "function" ]]; then
      warn "No handler for task '$name', skipping."
      TASK_RESULT[$name]='skipped (no handler)'
      continue
    fi
    blocked=''
    for dep in ${TASK_NEEDS[$name]:-}; do
      if [[ -n "${TASK_RESULT[$dep]+x}" && "${TASK_RESULT[$dep]}" != ok ]]; then blocked="$dep"; fi
    done
    if [[ -n "$blocked" ]]; then
      warn "Skipping $name: it needs $blocked, which did not finish."
      TASK_RESULT[$name]="skipped ($blocked did not finish)"
      RUN_FAILED=1
      continue
    fi
    echo "Task $name: $(task_desc_of "$name")"
    # Not "if ( ... )" or "( ... ) || ...": bash ignores errexit inside a
    # condition, which would let a failing command in a task go unnoticed.
    set +e
    ( set -e; load_task_config "$name"; "run_${name}" )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      TASK_RESULT[$name]=ok
      record_task_done "$name"
      say "Complete: $name"
    else
      TASK_RESULT[$name]=failed
      warn "Task $name failed (exit code $rc); going on with the next task."
      RUN_FAILED=1
    fi
  done
}

# Remember that task $1 finished on this Pi, so the autodeploy task knows
# which tasks to rerun. Best effort: a read-only state folder never fails a run.
record_task_done() {
  local f="${RPI_SETUP_DONE_FILE:-/var/lib/rpi-setup/tasks.done}"
  {
    mkdir -p "$(dirname "$f")" &&
      { cat "$f" 2>/dev/null || true; printf '%s\n' "$1"; } | sort -u >"$f.tmp" &&
      mv -f "$f.tmp" "$f"
  } 2>/dev/null || true
}

# The results table, reboot hint and log location printed at the end of a run.
print_summary() {
  local name
  hr
  echo 'Summary:'
  for name in "$@"; do
    printf '  %-14s %s\n' "$name" "${TASK_RESULT[$name]:-not run}"
  done
  if [[ -f "${RPI_SETUP_REBOOT_FILE:-/run/reboot-required}" ]] ||
     { [[ "${TASK_RESULT[base]:-}" == ok || "${TASK_RESULT[base]:-}" == failed ]] && is_pi; }; then
    info 'Reboot recommended: sudo reboot'
  fi
  if [[ -n "${RPI_SETUP_LOG_ACTIVE:-}" ]]; then
    info "Full log of this run: $RPI_SETUP_LOG_ACTIVE"
  fi
}

# Copy everything this run prints (stdout and stderr) to the log file. It is
# kept private because tasks print generated passwords. stdin is left alone,
# so prompts and '[[ -t 0 ]]' checks in tasks work as before.
RPI_SETUP_LOG="${RPI_SETUP_LOG:-/var/log/rpi-setup.log}"
RPI_SETUP_LOG_ACTIVE=''
_LOG_PID=''
_LOG_OUT=''
_LOG_ERR=''
start_log() {
  local log="$RPI_SETUP_LOG"
  if ! ( umask 077; touch "$log" && chmod 600 "$log" ) 2>/dev/null; then
    warn "Cannot write $log; this run is not logged."
    return 0
  fi
  printf '\n===== rpi-setup run %s: %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >>"$log"
  exec {_LOG_OUT}>&1 {_LOG_ERR}>&2
  exec > >(tee -a "$log") 2>&1
  _LOG_PID=$!
  RPI_SETUP_LOG_ACTIVE="$log"
  trap stop_log EXIT
}

# Restore the terminal and give tee a moment to write the last lines. The
# wait is bounded: a daemon a task started may still hold the pipe open.
stop_log() {
  [[ -n "$RPI_SETUP_LOG_ACTIVE" ]] || return 0
  exec 1>&"$_LOG_OUT" 2>&"$_LOG_ERR"
  exec {_LOG_OUT}>&- {_LOG_ERR}>&-
  RPI_SETUP_LOG_ACTIVE=''
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$_LOG_PID" 2>/dev/null || break
    sleep 0.2
  done
}

usage() {
  cat <<EOF
Usage: sudo bash setup.sh [task ...]   run tasks (no task: interactive menu)
       bash setup.sh --list            list the tasks
       bash setup.sh --init-config     create config/rpi-setup.env from the example
       bash setup.sh --split-config    split config/rpi-setup.env into config/local/<task>.env
       sudo bash setup.sh --move-config  move config/rpi-setup.env to $(system_config_dir) (root only)
Put your settings in $(central_config); setup.sh splits it into one
file per task before it runs any task. Settings are read from
$(system_config_dir)/rpi-setup.env when that file exists, so they can
live outside the git checkout.
EOF
}

main() {
  case "${1:-}" in
    --list)
      print_tasks
      return 0
      ;;
    --init-config)
      init_config
      return 0
      ;;
    --split-config)
      split_config "$(central_config)"
      return 0
      ;;
    --move-config)
      need_root
      move_config
      return 0
      ;;
    -h|--help)
      usage
      return 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
  esac

  need_root

  if ! is_pi; then
    warn 'This does not appear to be a Raspberry Pi. Some tasks may not work correctly.'
  fi

  local -a nums=()
  if [[ $# -gt 0 ]]; then
    nums=($(name_to_nums "$@"))
  else
    echo "rpi-setup - easy Raspberry Pi provisioning"
    echo
    echo 'Available tasks:'
    print_tasks
    echo
    echo 'Enter task numbers (comma/space separated), "all", or nothing to quit:'
    nums=($(prompt_selection))
    if [[ ${#nums[@]} -eq 0 ]]; then
      echo 'Cancelled.'
      return 0
    fi
  fi

  nums=($(dedupe "${nums[@]}"))
  if [[ ${#nums[@]} -eq 0 ]]; then
    echo 'Nothing to do.'
    return 0
  fi
  local -a picked=()
  local n
  for n in "${nums[@]}"; do
    if [[ -n "${TASKS[$((n - 1))]:-}" ]]; then picked+=("$(task_name "${TASKS[$((n - 1))]}")"); fi
  done
  if [[ ${#picked[@]} -eq 0 ]]; then
    echo 'Nothing to do.'
    return 0
  fi
  start_log "${picked[*]}"
  plan_tasks "${picked[@]}"
  warn_shadowed_config
  if [[ -f "$(central_config)" ]]; then
    split_config "$(central_config)"
  fi
  check_task_configs "${PLAN[@]}"
  run_tasks "${PLAN[@]}"
  print_summary "${PLAN[@]}"
  if [[ $RUN_FAILED -ne 0 ]]; then
    warn 'Some tasks did not finish; the lines above say why.'
  else
    say 'All selected tasks finished.'
  fi
  return "$RUN_FAILED"
}

# Only run when executed directly; ci/test-setup.sh sources this file to test
# the functions above without running any task.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi