#!/usr/bin/env bash
# Split the central settings file (config/rpi-setup.env, or the file given)
# into one file per task under config/local/, which setup.sh reads.
# setup.sh does this by itself before every run; this script is for checking
# the result, or for preparing config/local/ on another machine.
#
# Usage: bash config/split.sh [central-file]
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
split_config "$@"
