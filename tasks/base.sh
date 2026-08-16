#!/usr/bin/env bash
# Task: base - system baseline: updates, firmware, SSH, essentials.
set -euo pipefail

TASKS+=("base|OS update, EEPROM firmware, SSH enable, essential tools")

run_base() {
  info 'Refreshing apt lists'
  apt_update
  info 'Upgrading installed packages'
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs

  apt_install ca-certificates curl gnupg git unzip vim htop tmux fail2ban

  if command -v raspi-config >/dev/null 2>&1; then
    info 'Enabling SSH for headless access'
    raspi-config nonint do_ssh 1 2>/dev/null || true
  fi

  if command -v rpi-eeprom-update >/dev/null 2>&1; then
    info 'Updating EEPROM firmware (applies after a reboot)'
    rpi-eeprom-update -a 2>/dev/null || true
  fi

  if systemctl list-unit-files fstrim.timer >/dev/null 2>&1; then
    info 'Enabling periodic TRIM for SD/eMMC hygiene'
    systemctl enable --now fstrim.timer 2>/dev/null || true
  fi

  info 'Configuring fail2ban for SSH protection'
  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
    say 'Created /etc/fail2ban/jail.local with SSH protection'
  fi
  systemctl enable --now fail2ban || warn 'fail2ban could not be enabled/started; check its configuration.'
}
