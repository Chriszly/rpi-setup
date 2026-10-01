#!/usr/bin/env bash
# Task: base - system baseline: updates, firmware, SSH, essentials.
set -euo pipefail

TASKS+=("base|OS update, EEPROM firmware, SSH enable, essential tools")

run_base() {
  info 'Refreshing apt lists'
  apt_update
  if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]] || in_container; then
    info 'Skipping package upgrade in container/CI environment'
  else
    info 'Upgrading installed packages'
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs "${APT_DPKG_OPTS[@]}"
  fi

  # python3-systemd lets fail2ban read the journal: Raspberry Pi OS has no
  # /var/log/auth.log for the default file backend to watch.
  apt_install ca-certificates curl gnupg git unzip vim htop tmux fail2ban python3-systemd

  if command -v raspi-config >/dev/null 2>&1; then
    info 'Enabling SSH for headless access'
    # In raspi-config's nonint mode 0 means "enable"; 1 would switch SSH off.
    raspi-config nonint do_ssh 0 2>/dev/null || true
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
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
    say 'Created /etc/fail2ban/jail.local with SSH protection'
  fi
  systemctl enable --now fail2ban || warn 'fail2ban could not be enabled/started; check its configuration.'

  if [[ -f /run/reboot-required ]] || is_pi; then
    info 'Reboot when convenient (sudo reboot) so kernel and firmware updates take effect.'
  fi
}
