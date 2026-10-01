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

# Parse the settings file of every selected task before running any, so a typo
# in the last task's file stops the run before the first task changes anything.
check_task_configs() {
  local n entry
  for n in "$@"; do
    entry="${TASKS[$((n - 1))]:-}"
    [[ -n "$entry" ]] || continue
    ( load_task_config "$(task_name "$entry")" ) >/dev/null
  done
}

run_tasks() {
  local n entry name
  for n in "$@"; do
    entry="${TASKS[$((n - 1))]:-}"
    [[ -n "$entry" ]] || continue
    name="$(task_name "$entry")"
    if [[ "$(type -t "run_${name}")" != "function" ]]; then
      warn "No handler for task '$name', skipping."
      continue
    fi
    hr
    echo "Task $name: $(task_desc "$entry")"
    load_task_config "$name"
    "run_${name}"
    say "Complete: $name"
  done
  hr
  say "All selected tasks finished."
}

usage() {
  cat <<EOF
Usage: sudo bash setup.sh [task ...]   run tasks (no task: interactive menu)
       bash setup.sh --list            list the tasks
       bash setup.sh --init-config     create config/rpi-setup.env from the example
       bash setup.sh --split-config    split config/rpi-setup.env into config/local/<task>.env
Put your settings in $(central_config); setup.sh splits it into one
file per task before it runs any task.
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
  if [[ -f "$(central_config)" ]]; then
    split_config "$(central_config)"
  fi
  check_task_configs "${nums[@]}"
  # Plain call, not "A && B || C": bash disables errexit inside a && / ||
  # list, which would let failing commands in tasks go unnoticed.
  run_tasks "${nums[@]}"
}

# Only run when executed directly; ci/test-setup.sh sources this file to test
# the functions above without running any task.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi