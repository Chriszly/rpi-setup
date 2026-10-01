#!/usr/bin/env bash
# test-task-base.sh - unit tests for the hardening helpers in tasks/base.sh:
# setting validation, the generated config files and the authorized_keys
# guard that stops BASE_SSH_PASSWORD_AUTH=no from locking a user out.
# Nothing here changes the system; files are written to a temp folder only.
#
# Run: bash ci/test-task-base.sh
# The expected apt config holds a literal ${distro_codename}.
# shellcheck disable=SC2016
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/base.sh"

tmp="$TMP"

# Defaults as run_base sets them.
set_defaults() {
  BASE_AUTO_UPDATES=yes BASE_AUTO_REBOOT=no BASE_AUTO_REBOOT_TIME=03:30
  BASE_SSH_PASSWORD_AUTH=yes BASE_JOURNAL_MAX_SIZE=100M
}

# --- base_valid_time ----------------------------------------------------------
for t in 00:00 03:30 12:05 23:59; do assert_ok "base_valid_time accepts $t" base_valid_time "$t"; done
for t in 24:00 3:30 03:60 0330 '03:30 ' now ''; do assert_fails "base_valid_time rejects '$t'" base_valid_time "$t"; done

# --- base_valid_journal_size --------------------------------------------------
for s in 100M 50M 1G 512K 104857600 no NO; do assert_ok "journal size accepts $s" base_valid_journal_size "$s"; done
for s in 0 0M 100MB -1 1.5G 100m yes ''; do assert_fails "journal size rejects '$s'" base_valid_journal_size "$s"; done

# --- base_validate_hardening --------------------------------------------------
set_defaults
assert_ok "defaults validate" base_validate_hardening
assert_fails "BASE_AUTO_UPDATES=maybe dies" eval 'BASE_AUTO_UPDATES=maybe; base_validate_hardening'
assert_fails "BASE_AUTO_REBOOT=sometimes dies" eval 'BASE_AUTO_REBOOT=sometimes; base_validate_hardening'
assert_fails "BASE_AUTO_REBOOT_TIME=3am dies" eval 'BASE_AUTO_REBOOT_TIME=3am; base_validate_hardening'
assert_fails "BASE_SSH_PASSWORD_AUTH=perhaps dies" eval 'BASE_SSH_PASSWORD_AUTH=perhaps; base_validate_hardening'
assert_fails "BASE_JOURNAL_MAX_SIZE=lots dies" eval 'BASE_JOURNAL_MAX_SIZE=lots; base_validate_hardening'
assert_fails "BASE_SSH_PASSWORD_AUTH=no as root dies" \
  eval 'BASE_SSH_PASSWORD_AUTH=no; SUDO_USER=root; base_validate_hardening'
assert_contains "time error names the setting" "BASE_AUTO_REBOOT_TIME" \
  "$( (BASE_AUTO_REBOOT_TIME=25:00; base_validate_hardening) 2>&1 || true)"

# --- base_has_authorized_key / base_ssh_key_guard -----------------------------
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample0 me@pc'
mkdir -p "$tmp/empty/.ssh" "$tmp/comment/.ssh" "$tmp/good/.ssh" "$tmp/opts/.ssh" "$tmp/none" "$tmp/junk/.ssh"
: >"$tmp/empty/.ssh/authorized_keys"
printf '# %s\n\n' "$key" >"$tmp/comment/.ssh/authorized_keys"
printf '# my laptop\n%s\n' "$key" >"$tmp/good/.ssh/authorized_keys"
printf 'from="192.168.1.0/24",no-agent-forwarding %s\n' "$key" >"$tmp/opts/.ssh/authorized_keys"
printf 'hello world\n' >"$tmp/junk/.ssh/authorized_keys"

assert_fails "no authorized_keys file: no key" base_has_authorized_key "$tmp/none/.ssh/authorized_keys"
assert_fails "empty authorized_keys: no key" base_has_authorized_key "$tmp/empty/.ssh/authorized_keys"
assert_fails "commented-out key does not count" base_has_authorized_key "$tmp/comment/.ssh/authorized_keys"
assert_fails "text that is no key does not count" base_has_authorized_key "$tmp/junk/.ssh/authorized_keys"
assert_ok "a key line counts" base_has_authorized_key "$tmp/good/.ssh/authorized_keys"
assert_ok "a key with options counts" base_has_authorized_key "$tmp/opts/.ssh/authorized_keys"
printf 'ecdsa-sha2-nistp256 AAAAE2VjZHNh x\n' >"$tmp/ecdsa"
assert_ok "an ecdsa key counts" base_has_authorized_key "$tmp/ecdsa"
printf 'sk-ssh-ed25519@openssh.com AAAAGnNr x\n' >"$tmp/sk"
assert_ok "a security-key key counts" base_has_authorized_key "$tmp/sk"

assert_fails "guard refuses root" base_ssh_key_guard root "$tmp/good"
assert_fails "guard refuses a user without keys file" base_ssh_key_guard pi "$tmp/none"
assert_fails "guard refuses an empty keys file" base_ssh_key_guard pi "$tmp/empty"
assert_ok "guard accepts a user with a key" base_ssh_key_guard pi "$tmp/good"
msg="$( (base_ssh_key_guard pi "$tmp/empty") 2>&1 || true)"
assert_contains "guard names the keys file" "$tmp/empty/.ssh/authorized_keys" "$msg"
assert_contains "guard says how to fix it" "ssh-copy-id pi@" "$msg"
# A card flashed with an SSH key: the key sits in /etc/ssh/authorized_keys/<user>
# and the flasher's drop-in adds that path to AuthorizedKeysFile.
flashed='.ssh/authorized_keys .ssh/authorized_keys2 '"$tmp"'/etc-keys/%u'
mkdir -p "$tmp/etc-keys"; printf '%s\n' "$key" >"$tmp/etc-keys/pi"
assert_ok "guard accepts a key the flasher put in /etc/ssh/authorized_keys/<user>" \
  base_ssh_key_guard pi "$tmp/empty" "$flashed"
assert_fails "guard ignores that file when sshd does not read it" \
  base_ssh_key_guard pi "$tmp/empty" '.ssh/authorized_keys .ssh/authorized_keys2'
assert_fails "guard: the flashed key of another user does not count" \
  base_ssh_key_guard bob "$tmp/empty" "$flashed"
assert_ok "guard checks every listed file" base_ssh_key_guard pi "$tmp/good" '.ssh/nothing .ssh/authorized_keys'
assert_eq "key file tokens are expanded" \
  $'/home/pi/.ssh/authorized_keys\n/etc/ssh/authorized_keys/pi\n/home/pi/keys/%u' \
  "$(base_authorized_keys_files pi /home/pi '.ssh/authorized_keys /etc/ssh/authorized_keys/%u %h/keys/%%u none')"
assert_fails "guard refuses an unknown user" base_ssh_key_guard "no-such-user-$$"

# --- generated files ----------------------------------------------------------
set_defaults
assert_eq "sshd drop-in with passwords kept" \
  $'# Managed by rpi-setup (tasks/base.sh, BASE_SSH_PASSWORD_AUTH).\nPermitRootLogin no' \
  "$(base_sshd_conf)"
assert_eq "sshd drop-in key-only" \
  $'# Managed by rpi-setup (tasks/base.sh, BASE_SSH_PASSWORD_AUTH).\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no' \
  "$(BASE_SSH_PASSWORD_AUTH=no; base_sshd_conf)"
if command -v sshd >/dev/null 2>&1; then
  (BASE_SSH_PASSWORD_AUTH=no; base_sshd_conf) >"$tmp/sshd_config"
  out="$(sshd -t -f "$tmp/sshd_config" 2>&1 || true)"
  if grep -Eqi 'bad configuration option|unsupported option|deprecated option' <<<"$out"; then
    fail "sshd does not know an option of the drop-in: $out"
  else
    pass "sshd knows every option of the key-only drop-in"
  fi
else
  skip "sshd not installed; drop-in syntax not checked"
fi

assert_eq "journald drop-in" \
  $'# Managed by rpi-setup (tasks/base.sh, BASE_JOURNAL_MAX_SIZE).\n[Journal]\nSystemMaxUse=100M' \
  "$(base_journald_conf)"
assert_eq "journald drop-in follows the setting" "SystemMaxUse=1G" \
  "$(BASE_JOURNAL_MAX_SIZE=1G; base_journald_conf | tail -n1)"
assert_eq "BASE_JOURNAL_MAX_SIZE=no writes no drop-in" "" "$(BASE_JOURNAL_MAX_SIZE=no; base_journald_conf)"

assert_eq "20auto-upgrades on" \
  $'// Managed by rpi-setup (tasks/base.sh, BASE_AUTO_UPDATES).\nAPT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";' \
  "$(base_auto_upgrades_conf 1)"
assert_contains "20auto-upgrades off" 'APT::Periodic::Unattended-Upgrade "0";' "$(base_auto_upgrades_conf 0)"

uu="$(base_unattended_conf)"
assert_contains "unattended: origins are cleared first" '#clear Unattended-Upgrade::Origins-Pattern;' "$uu"
assert_contains "unattended: allowed origins are cleared" '#clear Unattended-Upgrade::Allowed-Origins;' "$uu"
assert_contains "unattended: Debian-Security origin" \
  '"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";' "$uu"
assert_contains "unattended: no reboot by default" 'Unattended-Upgrade::Automatic-Reboot "false";' "$uu"
assert_contains "unattended: reboot time" 'Unattended-Upgrade::Automatic-Reboot-Time "03:30";' "$uu"
assert_lacks "unattended: security origins only" 'label=Debian";' "$uu"
uu="$(BASE_AUTO_REBOOT=yes BASE_AUTO_REBOOT_TIME=04:15; base_unattended_conf)"
assert_contains "unattended: reboot on" 'Unattended-Upgrade::Automatic-Reboot "true";' "$uu"
assert_contains "unattended: custom reboot time" 'Unattended-Upgrade::Automatic-Reboot-Time "04:15";' "$uu"
if command -v apt-config >/dev/null 2>&1; then
  base_unattended_conf >"$tmp/apt.conf"
  if APT_CONFIG="$tmp/apt.conf" apt-config dump >/dev/null 2>&1; then
    pass "apt parses the unattended-upgrades file"
  else
    fail "apt cannot parse the file: $(APT_CONFIG="$tmp/apt.conf" apt-config dump 2>&1 | head -n3)"
  fi
else
  skip "apt-config not installed; unattended-upgrades file syntax not checked"
fi

finish_tests
