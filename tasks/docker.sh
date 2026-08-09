#!/usr/bin/env bash
# Task: docker - Docker Engine, buildx and compose as apt-packaged plugins.
set -euo pipefail

TASKS+=("docker|Docker Engine and Docker Compose")

run_docker() {
  if command -v docker >/dev/null 2>&1; then
    say "Docker is already installed ($(docker --version 2>/dev/null || true))"
    return
  fi

  local os_id vcode arch
  os_id=$( . /etc/os-release && echo "$ID" )
  vcode=$( . /etc/os-release && echo "$VERSION_CODENAME" )
  arch=$(dpkg --print-architecture)
  [[ -n "$os_id" ]] && [[ -n "$vcode" ]] || {
    die "Could not determine OS release (ID='${os_id}', VERSION_CODENAME='${vcode}'). Docker's apt repo needs both."
  }

  apt_install ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${vcode} stable" >/etc/apt/sources.list.d/docker.list

  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  local u
  u="$(real_user)"
  if [[ -n "$u" ]] && [[ "$u" != "root" ]]; then
    usermod -aG docker "$u"
    say "Added '$u' to the docker group (re-login to use it)"
  fi

  docker --version
  docker compose version
}