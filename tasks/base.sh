#!/usr/bin/env bash
# Task: base - system baseline: updates, firmware, SSH, essentials.
# Settings: BASE_* in config/rpi-setup.env (names in config/tasks/base.env).
set -euo pipefail

TASKS+=("base|OS update, EEPROM firmware, SSH enable, essential tools")

run_base() {
  : "${BASE_UPGRADE:=yes}" "${BASE_EEPROM_UPDATE:=yes}"
  : "${BASE_PCIE_GEN3:=no}" "${BASE_PI5_4K_KERNEL:=no}"
  : "${BASE_AUTO_UPDATES:=yes}" "${BASE_AUTO_REBOOT:=no}"
  : "${BASE_SSH_PASSWORD_AUTH:=yes}" "${BASE_JOURNAL_MAX_SIZE:=100M}"
  local hostname="${BASE_HOSTNAME:-}" tz="${BASE_TIMEZONE:-}" extra="${BASE_EXTRA_PACKAGES:-}" p
  local -a extra_pkgs=()

  # Validate every setting before changing anything.
  setting_on BASE_UPGRADE || true
  setting_on BASE_EEPROM_UPDATE || true
  setting_on BASE_PCIE_GEN3 || true
  setting_on BASE_PI5_4K_KERNEL || true
  if [[ -n "$hostname" ]] && ! valid_hostname "$hostname"; then
    die "BASE_HOSTNAME must be letters, digits and '-', at most 63 characters (got '$hostname')"
  fi
  if [[ -n "$tz" && ! -f "/usr/share/zoneinfo/$tz" ]]; then
    die "BASE_TIMEZONE '$tz' is not a known time zone (e.g. Europe/Berlin; list them with: timedatectl list-timezones)"
  fi
  base_validate_hardening
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

  base_auto_updates
  base_ssh_hardening
  base_journal_limit
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

# fail2ban's SSH jail: 5 failed logins within 10 minutes ban the address for
# an hour. The file is rewritten while it carries our marker; a hand-written
# jail.local is kept.
base_fail2ban() {
  local f=/etc/fail2ban/jail.local
  info 'Configuring fail2ban for SSH protection'
  if [[ -f "$f" ]] && ! grep -q 'Managed by rpi-setup' "$f" && ! base_is_old_jail "$f"; then
    warn "$f was not written by rpi-setup; leaving it alone"
    return
  fi
  if printf '%s\n' \
      '# Managed by rpi-setup (tasks/base.sh).' \
      '[sshd]' \
      'enabled = true' \
      'port = ssh' \
      'backend = systemd' \
      'maxretry = 5' \
      'bantime = 1h' \
      'findtime = 10m' | write_if_changed "$f" 0644; then
    say "Wrote $f (maxretry 5, bantime 1h)"
    if systemctl is-active --quiet fail2ban; then systemctl restart fail2ban || true; fi
  fi
}

# The unmarked jail.local that earlier versions of this task wrote.
base_is_old_jail() {
  [[ "$(cat "$1")" == $'[sshd]\nenabled = true\nport = ssh\nbackend = systemd\nmaxretry = 5\nbantime = 1h\nfindtime = 10m' ]]
}

# --- Hardening: security updates, SSH, journal size ------------------------

# Validate the BASE_AUTO_*, BASE_SSH_* and BASE_JOURNAL_* settings. With
# BASE_SSH_PASSWORD_AUTH=no this also refuses to go on unless the invoking
# user can log in with a key, so nobody locks themselves out.
base_validate_hardening() {
  setting_on BASE_AUTO_UPDATES || true
  setting_on BASE_AUTO_REBOOT || true
  setting_on BASE_SSH_PASSWORD_AUTH || true
  base_valid_journal_size "$BASE_JOURNAL_MAX_SIZE" ||
    die "BASE_JOURNAL_MAX_SIZE must be a size such as 50M, 100M or 1G, or 'no' to keep the journald default (got '$BASE_JOURNAL_MAX_SIZE')"
  if ! setting_on BASE_SSH_PASSWORD_AUTH; then base_ssh_key_guard "$(real_user)"; fi
}

# A journald size (bytes, or with a K/M/G/T suffix) or "no".
base_valid_journal_size() { [[ "${1,,}" == no || "$1" =~ ^[1-9][0-9]*[KMGT]?$ ]]; }

# True if file $1 holds at least one public key line (options before the key
# type are allowed; comments and blank lines do not count).
base_has_authorized_key() {
  [[ -s "$1" ]] && grep -Eq '^[^#]*(^|[[:space:]])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+AAAA' "$1"
}

# The AuthorizedKeysFile value sshd uses for user $1, from 'sshd -T' (which
# also reads the flasher's drop-in that adds /etc/ssh/authorized_keys/%u).
# Falls back to the OpenSSH default when sshd cannot report it.
base_sshd_keys_setting() {
  local line
  line="$(sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>/dev/null | grep -i '^authorizedkeysfile ')" || true
  if [[ -n "$line" ]]; then echo "${line#* }"; else echo '.ssh/authorized_keys .ssh/authorized_keys2'; fi
}

# Print the key files of AuthorizedKeysFile value $3 for user $1 with home
# $2, one per line: %h, %u and %% expanded, relative paths taken from $2.
base_authorized_keys_files() {
  local u="$1" home="$2" f
  for f in $3; do
    [[ "$f" == none ]] && continue
    f="${f//%%/$'\x01'}"; f="${f//%h/$home}"; f="${f//%u/$u}"; f="${f//$'\x01'/%}"
    [[ "$f" == /* ]] || f="$home/$f"
    echo "$f"
  done
}

# Die unless user $1 is a regular account with a key in one of the files sshd
# reads for it (~/.ssh/authorized_keys, or /etc/ssh/authorized_keys/<user>
# on a card written by host/flash.sh with an SSH key). $2 overrides the home
# directory and $3 the AuthorizedKeysFile value (for the unit tests).
base_ssh_key_guard() {
  local u="$1" home="${2:-}" setting="${3:-}" f files=()
  [[ "$u" != root ]] ||
    die "BASE_SSH_PASSWORD_AUTH=no: run setup with sudo from the account you log in with (root SSH login gets switched off), so its SSH keys can be checked."
  if [[ -z "$home" ]]; then
    home="$(getent passwd "$u" | cut -d: -f6)" || true
  fi
  [[ -n "$home" ]] || die "BASE_SSH_PASSWORD_AUTH=no: cannot find the home directory of user '$u'."
  [[ -n "$setting" ]] || setting="$(base_sshd_keys_setting "$u")"
  mapfile -t files < <(base_authorized_keys_files "$u" "$home" "$setting")
  for f in "${files[@]}"; do
    base_has_authorized_key "$f" && return 0
  done
  die "BASE_SSH_PASSWORD_AUTH=no would lock you out: none of ${files[*]:-the key files} holds an SSH public key. From your PC run 'ssh-copy-id $u@<pi>', check that 'ssh $u@<pi>' logs in without a password, then re-run. Or keep BASE_SSH_PASSWORD_AUTH=yes."
}

# /etc/apt/apt.conf.d/20auto-upgrades: $1 is 1 (on) or 0 (off).
base_auto_upgrades_conf() {
  printf '%s\n' \
    '// Managed by rpi-setup (tasks/base.sh, BASE_AUTO_UPDATES).' \
    "APT::Periodic::Update-Package-Lists \"$1\";" \
    "APT::Periodic::Unattended-Upgrade \"$1\";"
}

# /etc/apt/apt.conf.d/52rpi-setup-unattended-upgrades. The package's own
# 50unattended-upgrades also installs Debian point-release updates; this
# narrows it to the Debian security archive. Raspberry Pi OS has no security
# suite of its own (kernel and firmware come from archive.raspberrypi.com and
# are updated by BASE_UPGRADE runs instead). Both origin lists are cleared, so
# only the patterns below apply.
base_unattended_conf() {
  local reboot=false
  if setting_on BASE_AUTO_REBOOT; then reboot=true; fi
  # shellcheck disable=SC2016 # ${distro_codename} is expanded by unattended-upgrades
  printf '%s\n' \
    '// Managed by rpi-setup (tasks/base.sh, BASE_AUTO_* settings).' \
    '#clear Unattended-Upgrade::Allowed-Origins;' \
    '#clear Unattended-Upgrade::Origins-Pattern;' \
    'Unattended-Upgrade::Origins-Pattern {' \
    '  "origin=Debian,codename=${distro_codename},label=Debian-Security";' \
    '  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";' \
    '};' \
    "Unattended-Upgrade::Automatic-Reboot \"$reboot\";" \
    'Unattended-Upgrade::Automatic-Reboot-Time "03:30";'
}

base_auto_updates() {
  local periodic=/etc/apt/apt.conf.d/20auto-upgrades
  local ours=/etc/apt/apt.conf.d/52rpi-setup-unattended-upgrades reboot=no
  if ! setting_on BASE_AUTO_UPDATES; then
    # Switch off only what this task switched on earlier.
    if [[ -f "$periodic" ]] && grep -q 'Managed by rpi-setup' "$periodic"; then
      if base_auto_upgrades_conf 0 | write_if_changed "$periodic" 0644; then
        say 'Automatic security updates switched off (BASE_AUTO_UPDATES=no)'
      fi
      rm -f "$ours"
    else
      info 'Skipping automatic security updates (BASE_AUTO_UPDATES=no)'
    fi
    return 0
  fi
  info 'Setting up automatic security updates (unattended-upgrades)'
  apt_install unattended-upgrades
  base_auto_upgrades_conf 1 | write_if_changed "$periodic" 0644 || true
  if setting_on BASE_AUTO_REBOOT; then reboot="yes, at 03:30"; fi
  if base_unattended_conf | write_if_changed "$ours" 0644; then
    say "Wrote $ours (reboot after updates: $reboot)"
  fi
  if grep -rqs 'raspbian\.raspberrypi' /etc/apt/sources.list /etc/apt/sources.list.d; then
    warn '32-bit Raspberry Pi OS (Raspbian) has no separate security archive, so automatic security updates find nothing there. Use the 64-bit OS, or re-run "setup.sh base" now and then.'
  fi
  if in_container; then
    info 'Container detected: not starting the apt-daily timers'
  else
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null ||
      warn 'Could not enable the apt-daily timers; automatic updates may not run.'
  fi
}

# /etc/ssh/sshd_config.d/10-rpi-setup.conf. Debian's sshd_config includes
# sshd_config.d/*.conf first and sshd keeps the first value it reads, so this
# file wins over settings further down.
base_sshd_conf() {
  printf '%s\n' \
    '# Managed by rpi-setup (tasks/base.sh, BASE_SSH_PASSWORD_AUTH).' \
    'PermitRootLogin no'
  if ! setting_on BASE_SSH_PASSWORD_AUTH; then
    printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no'
  fi
}

base_ssh_hardening() {
  local f=/etc/ssh/sshd_config.d/10-rpi-setup.conf old="" had=0 eff
  if [[ -f "$f" ]]; then old="$(cat "$f")"; had=1; fi
  install -m 0755 -d /etc/ssh/sshd_config.d
  base_sshd_conf | write_if_changed "$f" 0644 || return 0
  if ! command -v sshd >/dev/null 2>&1; then
    info "Wrote $f; the OpenSSH server is not installed, so there is nothing to reload"
    return 0
  fi
  install -m 0755 -d /run/sshd
  if ! sshd -t; then
    if (( had )); then printf '%s\n' "$old" >"$f"; else rm -f "$f"; fi
    die "sshd rejected the new $f, so it was rolled back. Check the SSH configuration with: sudo sshd -t"
  fi
  if in_container; then
    info "Wrote $f; container detected, not reloading ssh"
  else
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null ||
      warn 'Could not reload ssh; the new SSH settings apply after: sudo systemctl restart ssh'
  fi
  if setting_on BASE_SSH_PASSWORD_AUTH; then
    say 'SSH: root login off, password login kept (BASE_SSH_PASSWORD_AUTH=yes)'
    return 0
  fi
  eff="$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')" || true
  if [[ -n "$eff" && "$eff" != no ]]; then
    warn "sshd still allows passwords: /etc/ssh/sshd_config probably lacks 'Include /etc/ssh/sshd_config.d/*.conf' near its top."
  else
    say 'SSH: root login off, key-only login (password login switched off)'
  fi
}

# /etc/systemd/journald.conf.d/10-rpi-setup.conf; no output means "no file".
base_journald_conf() {
  [[ "${BASE_JOURNAL_MAX_SIZE,,}" != no ]] || return 0
  printf '%s\n' \
    '# Managed by rpi-setup (tasks/base.sh, BASE_JOURNAL_MAX_SIZE).' \
    '[Journal]' \
    "SystemMaxUse=$BASE_JOURNAL_MAX_SIZE"
}

base_journal_limit() {
  local f=/etc/systemd/journald.conf.d/10-rpi-setup.conf body changed=no
  body="$(base_journald_conf)"
  if [[ -z "$body" ]]; then
    if [[ -f "$f" ]]; then
      rm -f "$f"
      changed=yes
      say 'Journal size limit removed (BASE_JOURNAL_MAX_SIZE=no)'
    fi
  else
    install -m 0755 -d /etc/systemd/journald.conf.d
    if printf '%s\n' "$body" | write_if_changed "$f" 0644; then
      changed=yes
      say "Journal limited to $BASE_JOURNAL_MAX_SIZE on disk ($f)"
    fi
  fi
  [[ "$changed" == yes ]] || return 0
  if in_container; then
    info 'Container detected: not restarting systemd-journald'
  else
    systemctl restart systemd-journald || warn 'Could not restart systemd-journald; the journal limit applies after a reboot.'
  fi
}
