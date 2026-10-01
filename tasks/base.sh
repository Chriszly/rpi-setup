#!/usr/bin/env bash
# Task: base - system baseline: updates, firmware, SSH, essentials.
# Settings: BASE_* in config/rpi-setup.env (names in config/tasks/base.env).
set -euo pipefail

TASKS+=("base|OS update, EEPROM firmware, SSH enable, essential tools")

run_base() {
  : "${BASE_UPGRADE:=yes}" "${BASE_EEPROM_UPDATE:=yes}"
  : "${BASE_FAIL2BAN_MAXRETRY:=5}" "${BASE_FAIL2BAN_BANTIME:=1h}"
  : "${BASE_PCIE_GEN3:=no}" "${BASE_PI5_4K_KERNEL:=no}"
  local hostname="${BASE_HOSTNAME:-}" tz="${BASE_TIMEZONE:-}" extra="${BASE_EXTRA_PACKAGES:-}" p
  local -a extra_pkgs=()

  # Validate every setting before changing anything.
  setting_on BASE_UPGRADE || true
  setting_on BASE_EEPROM_UPDATE || true
  setting_on BASE_PCIE_GEN3 || true
  setting_on BASE_PI5_4K_KERNEL || true
  [[ "$BASE_FAIL2BAN_MAXRETRY" =~ ^[1-9][0-9]*$ ]] ||
    die "BASE_FAIL2BAN_MAXRETRY must be a positive number (got '$BASE_FAIL2BAN_MAXRETRY')"
  [[ "$BASE_FAIL2BAN_BANTIME" =~ ^(-1|[1-9][0-9]*[smhdw]?)$ ]] ||
    die "BASE_FAIL2BAN_BANTIME must look like 600, 10m, 1h, 1d or -1 (got '$BASE_FAIL2BAN_BANTIME')"
  if [[ -n "$hostname" ]] && ! valid_hostname "$hostname"; then
    die "BASE_HOSTNAME must be letters, digits and '-', at most 63 characters (got '$hostname')"
  fi
  if [[ -n "$tz" && ! -f "/usr/share/zoneinfo/$tz" ]]; then
    die "BASE_TIMEZONE '$tz' is not a known time zone (e.g. Europe/Berlin; list them with: timedatectl list-timezones)"
  fi
  if [[ -n "$extra" ]]; then
    read -r -a extra_pkgs <<<"${extra//,/ }"
    for p in "${extra_pkgs[@]}"; do
      [[ "$p" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "BASE_EXTRA_PACKAGES: '$p' is not a package name"
    done
  fi
  base_check_os

  info 'Refreshing apt lists'
  apt_update
  if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]] || in_container; then
    info 'Skipping package upgrade in container/CI environment'
  elif setting_on BASE_UPGRADE; then
    info 'Upgrading installed packages'
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs "${APT_DPKG_OPTS[@]}"
  else
    info 'Skipping package upgrade (BASE_UPGRADE=no)'
  fi

  # python3-systemd lets fail2ban read the journal: Raspberry Pi OS has no
  # /var/log/auth.log for the default file backend to watch.
  apt_install ca-certificates curl gnupg git unzip vim htop tmux fail2ban python3-systemd "${extra_pkgs[@]}"

  if command -v raspi-config >/dev/null 2>&1; then
    info 'Enabling SSH for headless access'
    # In raspi-config's nonint mode 0 means "enable"; 1 would switch SSH off.
    raspi-config nonint do_ssh 0 2>/dev/null || true
  fi

  if [[ -n "$hostname" ]]; then base_set_hostname "$hostname"; fi
  if [[ -n "$tz" ]]; then base_set_timezone "$tz"; fi

  if setting_on BASE_EEPROM_UPDATE && command -v rpi-eeprom-update >/dev/null 2>&1; then
    info 'Updating EEPROM firmware (applies after a reboot)'
    rpi-eeprom-update -a 2>/dev/null || true
  fi

  base_pi5_boot_config

  if systemctl list-unit-files fstrim.timer >/dev/null 2>&1; then
    info 'Enabling periodic TRIM for SD/eMMC hygiene'
    systemctl enable --now fstrim.timer 2>/dev/null || true
  fi

  base_fail2ban
  systemctl enable --now fail2ban || warn 'fail2ban could not be enabled/started; check its configuration.'

  if [[ -f /run/reboot-required ]] || is_pi; then
    info 'Reboot when convenient (sudo reboot) so kernel and firmware updates take effect.'
  fi
}


# The Pi 5 needs Bookworm or newer, and teamspeak's image is 64-bit only.
base_check_os() {
  local codename arch
  codename=$( . /etc/os-release && echo "${VERSION_CODENAME:-}" ) || true
  arch="$(dpkg --print-architecture)"
  if is_pi5 && [[ "$codename" == bullseye || "$codename" == buster ]]; then
    die "A Raspberry Pi 5 needs Raspberry Pi OS Bookworm or newer (this is $codename). Flash a current image with host/flash.sh or host/flash.ps1."
  fi
  if is_pi5 && [[ "$arch" != arm64 ]]; then
    warn "This Pi 5 runs a 32-bit ($arch) OS; the teamspeak task needs Raspberry Pi OS Lite (64-bit)."
  fi
}

base_set_hostname() {
  local new="$1" old
  old="$(hostname)"
  if [[ "$old" == "$new" ]]; then
    say "Hostname is already $new"
    return
  fi
  info "Renaming this Pi from $old to $new"
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_hostname "$new"
  else
    hostnamectl set-hostname "$new"
    sed -Ei "s/^(127\.0\.1\.1[[:space:]]+).*/\1$new/" /etc/hosts
    grep -q '^127\.0\.1\.1' /etc/hosts || printf '127.0.1.1\t%s\n' "$new" >>/etc/hosts
  fi
  say "Hostname set to $new (reachable as $new.local after a reboot)"
}

base_set_timezone() {
  local tz="$1"
  if [[ "$(readlink -f /etc/localtime 2>/dev/null)" == "$(readlink -f "/usr/share/zoneinfo/$tz")" ]]; then
    say "Time zone is already $tz"
    return
  fi
  if ! timedatectl set-timezone "$tz" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    printf '%s\n' "$tz" >/etc/timezone
  fi
  say "Time zone set to $tz"
}

# Pi 5 only options, kept in a marked block at the end of config.txt. With
# both settings off the block is removed again.
base_pi5_boot_config() {
  local conf lines=""
  if setting_on BASE_PCIE_GEN3; then lines+=$'# BASE_PCIE_GEN3: PCIe Gen 3 for an NVMe HAT\ndtparam=pciex1_gen=3\n'; fi
  if setting_on BASE_PI5_4K_KERNEL; then lines+=$'# BASE_PI5_4K_KERNEL: 4K-page kernel for software that fails on 16K pages\nkernel=kernel8.img\n'; fi
  if [[ -n "$lines" ]] && ! is_pi5; then
    warn 'BASE_PCIE_GEN3 and BASE_PI5_4K_KERNEL only apply to a Raspberry Pi 5; ignoring them here.'
    return
  fi
  if ! conf="$(boot_config_file)"; then
    [[ -z "$lines" ]] || warn 'No config.txt found; cannot apply the Pi 5 boot options.'
    return
  fi
  if printf '%s' "$lines" | boot_config_block "$conf"; then
    say "Updated the Pi 5 boot options in $conf (applies after a reboot)"
  fi
}

# fail2ban's SSH jail. The file is rewritten while it carries our marker, so
# changed settings apply on a re-run; a hand-written jail.local is kept.
base_fail2ban() {
  local f=/etc/fail2ban/jail.local
  info 'Configuring fail2ban for SSH protection'
  if [[ -f "$f" ]] && ! grep -q 'Managed by rpi-setup' "$f" && ! base_is_old_jail "$f"; then
    warn "$f was not written by rpi-setup; leaving it alone (BASE_FAIL2BAN_* not applied)"
    return
  fi
  if printf '%s\n' \
      '# Managed by rpi-setup (tasks/base.sh, BASE_FAIL2BAN_* settings).' \
      '[sshd]' \
      'enabled = true' \
      'port = ssh' \
      'backend = systemd' \
      "maxretry = ${BASE_FAIL2BAN_MAXRETRY}" \
      "bantime = ${BASE_FAIL2BAN_BANTIME}" \
      'findtime = 10m' | write_if_changed "$f" 0644; then
    say "Wrote $f (maxretry ${BASE_FAIL2BAN_MAXRETRY}, bantime ${BASE_FAIL2BAN_BANTIME})"
    if systemctl is-active --quiet fail2ban; then systemctl restart fail2ban || true; fi
  fi
}

# The unmarked jail.local that earlier versions of this task wrote.
base_is_old_jail() {
  [[ "$(cat "$1")" == $'[sshd]\nenabled = true\nport = ssh\nbackend = systemd\nmaxretry = 5\nbantime = 1h\nfindtime = 10m' ]]
}
