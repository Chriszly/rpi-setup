#!/usr/bin/env bash
# test-no-secrets.sh - unit tests for the rules in .gitleaks.toml.
#
# Each case commits files to a throw-away git repository and runs gitleaks
# on it. Needs gitleaks on PATH (the workflow's gitleaks step installs it).
# Run: bash ci/test-no-secrets.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

command -v gitleaks >/dev/null || { echo 'gitleaks is not installed: https://github.com/gitleaks/gitleaks#installing' >&2; exit 1; }

# repo NAME FILE CONTENT - a fresh repository holding the example plus FILE.
repo() {
  local d="$TMP/$1"
  mkdir -p "$d/config/tasks" "$(dirname "$d/$2")"
  printf 'SAMBA_PASSWORD=\n#FLASH_WIFI_PASSWORD=\n' >"$d/config/rpi-setup.env.example"
  printf 'SAMBA_PASSWORD=\n' >"$d/config/tasks/samba.env"
  printf '%b' "$3" >"$d/$2"
  git -C "$d" init -q
  git -C "$d" add -f .
  git -C "$d" -c user.name=test -c user.email=test@example.com commit -qm test
  printf '%s\n' "$d"
}
check() { gitleaks git --no-banner --no-color --redact -v --config "$ROOT/.gitleaks.toml" "$1"; }

# A key long enough for gitleaks' private-key rule, split so this file does not hold one.
begin='-----BEGIN' end='-----END'
body='b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW'

assert_ok "empty and commented passwords are fine" check "$(repo clean README.md 'TAILSCALE_AUTHKEY=tskey-auth-...\n')"
assert_fails "a filled config/rpi-setup.env is caught" check "$(repo filled config/rpi-setup.env 'WEB_PORT=80\n')"
assert_fails "split files are caught" check "$(repo split config/local/samba.env "SAMBA_PASSWORD=''\n")"
assert_fails "a password in the example is caught" check "$(repo example config/rpi-setup.env.example 'SAMBA_PASSWORD=hunter2\n')"
assert_fails "an exported token is caught" check "$(repo token config/tasks/web.env 'export WEB_TOKEN=abc\n')"
assert_fails "a private key is caught" check \
  "$(repo key keys/id_ed25519 "$begin OPENSSH PRIVATE KEY-----\n$body\n$end OPENSSH PRIVATE KEY-----\n")"
assert_fails "an RSA private key is caught" check \
  "$(repo rsa keys/pi.pem "$begin RSA PRIVATE KEY-----\n$body\n$end RSA PRIVATE KEY-----\n")"
assert_ok "a public key is fine" check "$(repo pub keys/id_ed25519.pub 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA me@pc\n')"
assert_fails "a Tailscale auth key is caught" check \
  "$(repo ts notes.md "key: tskey"'-auth-kAbCdE1CNTRL-0123456789abcdefXYZ\n')"
assert_contains "the failure names the file" "config/rpi-setup.env" \
  "$(check "$TMP/filled" 2>&1 || true)"
assert_contains "the failure names the file, rule and line" "config/rpi-setup.env.example:rpi-setup-filled-password:1" \
  "$(check "$TMP/example" 2>&1 || true)"
assert_eq "the value itself is not printed" "" "$(check "$TMP/example" 2>&1 | grep hunter2 || true)"

finish_tests
