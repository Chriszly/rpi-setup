#!/usr/bin/env bash
# check-no-secrets.sh - fail when a commit would publish device settings.
#
# This repository is public, so it must never hold a filled settings file,
# a private key or a real password. Checks every file git tracks in DIR
# (default: this checkout):
#   - no config/rpi-setup.env, config/local/ or other *.env besides the
#     example and the config/tasks/ name lists
#   - no line starting with "-----BEGIN ... PRIVATE KEY-----"
#   - no tracked *.env line giving a *PASSWORD, *AUTHKEY, *TOKEN or *SECRET a value
#   - no Tailscale auth key (tskey-...)
#
# Run: bash ci/check-no-secrets.sh [DIR]
set -euo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$DIR"
problems=0
problem() { printf '[FAIL] %s\n' "$*" >&2; problems=$((problems + 1)); }

while IFS= read -r f; do
  case "$f" in
    config/rpi-setup.env.example|config/tasks/*.env) ;;
    *.env|*.env.*|config/local/*) problem "$f is a settings file; keep filled settings out of this public repository" ;;
  esac
done < <(git ls-files)

while IFS= read -r hit; do
  problem "${hit%%:*}: holds a private key"
done < <(git grep -lE -e '^-----BEGIN ([A-Z]+ )*PRIVATE KEY-----' || true)

while IFS= read -r hit; do
  problem "$hit: a password or key has a value in a committed settings file"
done < <(git grep -nE -e '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(PASSWORD|AUTHKEY|TOKEN|SECRET)=[[:space:]]*[^[:space:]#]' \
           -- '*.env' '*.env.*' | cut -d: -f1,2 || true)

while IFS= read -r hit; do
  problem "$hit: looks like a Tailscale auth key"
done < <(git grep -nE -e 'tskey-[a-z]+-[A-Za-z0-9]{6,}-[A-Za-z0-9]{10,}' | cut -d: -f1,2 || true)

if [[ $problems -gt 0 ]]; then
  echo "Found $problems possible secret(s). Keep device settings in a private folder outside this repository." >&2
  exit 1
fi
echo '[PASS] No settings files, private keys or passwords are tracked.'
